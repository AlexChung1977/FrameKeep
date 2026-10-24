import AVFoundation
import AppKit
import Combine
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

final class CapturePipeline: NSObject, ObservableObject {
    @Published var phase: CapturePhase = .idle
    @Published var displays: [CaptureDisplay] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var includeMicrophone = false
    @Published var includeSystemAudio = true
    @Published var elapsed: TimeInterval = 0
    @Published var audioLevel: Float = 0
    @Published var previewImage: NSImage?
    @Published var permission = CapturePermissionState.unknown
    @Published var hint: String = "請先在瀏覽器播放要收錄的內容，再開始擷取。"
    @Published var lastError: String?

    private let videoQueue = DispatchQueue(label: "app.framekeep.capture.video")
    private let audioQueue = DispatchQueue(label: "app.framekeep.capture.audio")
    private let previewQueue = DispatchQueue(label: "app.framekeep.capture.preview", qos: .utility)
    private let writerLock = NSLock()
    private let previewLock = NSLock()
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var stream: SCStream?
    private var activeStream: SCStream?
    private var streamDisplayID: CGDirectDisplayID?
    private var previewGeneration = 0
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var lastVideoPTS = CMTime.invalid
    private var lastAudioPTS = CMTime.invalid
    private var sessionStarted = false
    private var sessionStart = CMTime.zero
    private var audioConverter: AVAudioConverter?
    private var audioOutputFormat: AVAudioFormat?
    private var retainedVideo: CMSampleBuffer?
    private var audioWaitStarted: Date?
    private var streamCapturesAudio = false
    private var attemptedAudioRecovery = false
    private var ffmpegPath = ""
    private var systemAudioFile: AVAudioFile?
    private var systemAudioURL: URL?
    private var micFile: AVAudioFile?
    private var micURL: URL?
    private var micConverter: AVAudioConverter?
    private var micFormat: AVAudioFormat?
    private let audioFileLock = NSLock()
    var audioMixNote: String?
    private var outputURL: URL?
    private var startedAt: Date?
    private var elapsedTimer: Timer?
    private var previewCounter = 0
    private var previewInFlight = false
    private var captureFPS: Int32 = 60
    private var audioEngine: AVAudioEngine?
    private var recording = false
    private var paused = false
    private var didRequestScreen = false
    private var screenVerified = false
    private var contentProbeInFlight = false
    private var didAutoProbe = false
    private var retryWhenActive = false
    private var previewTask: Task<Void, Never>?
    private let levelLock = NSLock()
    private var lastLevelPublish = Date.distantPast
    private var pendingLevel: Float = 0
    private var levelPublishQueued = false

    private static let relaunchAfterGrantMessage = "請在「系統設定 → 隱私權與安全性 → 螢幕與系統錄音」把 Framekeep 關掉再打開，然後按 ⌘Q 重新開啟。"
    private static let defaultHint = "請先在瀏覽器播放要收錄的內容，再開始擷取。"
    private static let displayWithoutAudioHint = "這台顯示器只擷取畫面。系統音訊請改回主螢幕。"

    var elapsedLabel: String {
        let total = Int(elapsed.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    var selectedDisplay: CaptureDisplay? {
        displays.first(where: { $0.id == selectedDisplayID }) ?? displays.first
    }

    func refreshPermissions() {
        let probed = PermissionPrompter.currentState()
        let next = CapturePermissionState(
            screenGranted: probed.screenGranted || screenVerified,
            microphoneGranted: probed.microphoneGranted
        )
        if permission != next {
            permission = next
        }
        if permission.screenGranted {
            if lastError == Self.relaunchAfterGrantMessage {
                lastError = nil
            }
            switch phase {
            case .idle, .requestingPermission, .failed(Self.relaunchAfterGrantMessage):
                phase = .ready
            default:
                break
            }
        }
    }

    func requestPermissions(includingMicrophone: Bool) async {
        await MainActor.run { phase = .requestingPermission }
        await refreshShareableContent()
        if await MainActor.run(body: { screenVerified }) {
            await finishScreenAccess(includingMicrophone: includingMicrophone)
            return
        }
        if !didRequestScreen {
            didRequestScreen = true
            _ = PermissionPrompter.requestScreen()
            await refreshShareableContent()
            if await MainActor.run(body: { screenVerified || PermissionPrompter.screenGranted() }) {
                await finishScreenAccess(includingMicrophone: includingMicrophone)
                return
            }
        }
        await MainActor.run { retryWhenActive = true }
        PermissionPrompter.openScreenRecordingSettings()
        await MainActor.run {
            lastError = Self.relaunchAfterGrantMessage
            phase = .failed(Self.relaunchAfterGrantMessage)
        }
    }

    func prepareIfPermitted() async {
        let shouldProbe = await MainActor.run { () -> Bool in
            refreshPermissions()
            if screenVerified || contentProbeInFlight { return false }
            if didAutoProbe && !retryWhenActive { return false }
            didAutoProbe = true
            retryWhenActive = false
            contentProbeInFlight = true
            return true
        }
        guard shouldProbe else { return }
        await refreshShareableContent()
        let verified = await MainActor.run { () -> Bool in
            contentProbeInFlight = false
            return screenVerified
        }
        if verified {
            await startPreview()
        }
    }

    func refreshShareableContent() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let mapped = content.displays.map { display -> CaptureDisplay in
                let pixels = Self.nativePixelSize(for: display)
                return CaptureDisplay(
                    id: display.displayID,
                    name: Self.screenName(for: display.displayID),
                    width: pixels.width,
                    height: pixels.height,
                    isMain: CGMainDisplayID() == display.displayID
                )
            }
            await MainActor.run {
                displays = mapped
                if selectedDisplayID == nil || !mapped.contains(where: { $0.id == selectedDisplayID }) {
                    selectedDisplayID = mapped.first(where: { $0.isMain })?.id ?? mapped.first?.id
                }
                noteScreenVerified()
                if mapped.isEmpty {
                    lastError = "找不到可擷取的顯示器。"
                    phase = .failed(lastError ?? "")
                }
            }
        } catch {
            await MainActor.run {
                guard displays.isEmpty else { return }
                lastError = "無法列出顯示器：\(error.localizedDescription)。\(Self.relaunchAfterGrantMessage)"
                phase = .failed(lastError ?? "")
            }
        }
    }

    func selectDisplay(_ id: CGDirectDisplayID) async {
        let shouldRestart = await MainActor.run { () -> Bool in
            guard phase != .recording, phase != .paused, phase != .saving else {
                lastError = "錄製中無法切換顯示器。"
                return false
            }
            guard selectedDisplayID != id else { return false }
            selectedDisplayID = id
            previewImage = nil
            lastError = nil
            previewGeneration += 1
            return true
        }
        guard shouldRestart else { return }
        await enqueuePreview(previewGeneration).value
    }

    func startPreview() async {
        guard stream == nil else { return }
        previewGeneration += 1
        await enqueuePreview(previewGeneration).value
    }

    @discardableResult
    private func enqueuePreview(_ generation: Int) -> Task<Void, Never> {
        let previous = previewTask
        let task = Task { [weak self] in
            await previous?.value
            await self?.runPreview(generation)
        }
        previewTask = task
        return task
    }

    private func runPreview(_ generation: Int) async {
        guard generation == previewGeneration else { return }
        await stopActiveStream()
        guard generation == previewGeneration else { return }
        do {
            try await installStream()
            guard generation == previewGeneration else {
                await stopActiveStream()
                return
            }
            await MainActor.run { noteScreenVerified() }
        } catch {
            guard generation == previewGeneration else { return }
            await MainActor.run {
                lastError = AppError.captureFailed(error.localizedDescription).localizedChinese
                phase = .failed(self.lastError ?? "")
            }
        }
    }

    private func ensureStreamForSelection() async throws {
        await previewTask?.value
        if stream != nil, streamDisplayID == selectedDisplayID { return }
        await stopActiveStream()
        try await installStream()
    }

    private func stopActiveStream() async {
        guard let stream else { return }
        activeStream = nil
        await stopStream(stream)
        self.stream = nil
        streamDisplayID = nil
        streamCapturesAudio = false
    }

    private func finishScreenAccess(includingMicrophone: Bool) async {
        if includingMicrophone, !PermissionPrompter.microphoneGranted() {
            _ = await PermissionPrompter.requestMicrophone()
        }
        await refreshShareableContent()
        await startPreview()
        await MainActor.run {
            refreshPermissions()
            if screenVerified || permission.screenGranted {
                phase = .ready
                lastError = nil
            }
        }
    }

    private func noteScreenVerified() {
        screenVerified = true
        permission = CapturePermissionState(
            screenGranted: true,
            microphoneGranted: permission.microphoneGranted || PermissionPrompter.microphoneGranted()
        )
        lastError = nil
        switch phase {
        case .idle, .requestingPermission, .failed:
            phase = .ready
        default:
            break
        }
    }

    func startRecording(root: URL, ffmpegPath: String) async {
        self.ffmpegPath = ffmpegPath
        audioMixNote = nil
        await MainActor.run {
            lastError = nil
            refreshPermissions()
        }
        let granted = await MainActor.run { permission.screenGranted }
        if !granted {
            await requestPermissions(includingMicrophone: includeMicrophone)
            let ready = await MainActor.run { permission.screenGranted }
            guard ready else { return }
        }
        let needsMic = await MainActor.run { includeMicrophone && !permission.microphoneGranted }
        if needsMic {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await PermissionPrompter.requestMicrophone()
                await MainActor.run { refreshPermissions() }
            }
            let micOK = await MainActor.run { permission.microphoneGranted }
            if !micOK {
                await MainActor.run {
                    lastError = AppError.permissionDenied("麥克風").localizedChinese
                }
                return
            }
        }

        attemptedAudioRecovery = false
        do {
            try AppPaths.ensureDirectory(AppPaths.incompleteDirectory(root: root))
            let url = AppPaths.incompleteDirectory(root: root)
                .appendingPathComponent("capture-\(UUID().uuidString).mov")
            try await ensureStreamForSelection()
            try prepareWriter(url: url)
            recording = true
            paused = false
            startedAt = Date()
            await MainActor.run {
                phase = .recording
                elapsed = 0
            }
            await MainActor.run { startTimer() }
            if includeMicrophone {
                do {
                    try startMicrophone()
                } catch {
                    audioMixNote = "麥克風沒有開始錄音。"
                }
            }
        } catch {
            let message = Self.captureMessage(error)
            await MainActor.run {
                phase = .failed(message)
                lastError = message
            }
            teardownWriter()
        }
    }

    func pauseOrResume() {
        guard recording else { return }
        paused.toggle()
        phase = paused ? .paused : .recording
        if paused {
            elapsedTimer?.invalidate()
        } else {
            startedAt = Date().addingTimeInterval(-elapsed)
            startTimer()
        }
    }

    func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        await MainActor.run { phase = .saving }
        recording = false
        paused = false
        elapsedTimer?.invalidate()
        stopMicrophone()
        await stopActiveStream()

        let duration = elapsed
        let finishedURL: URL = try await withCheckedThrowingContinuation { continuation in
            writerLock.lock()
            let writer = self.writer
            let videoInput = self.videoInput
            let audioInput = self.audioInput
            let outputURL = self.outputURL
            writerLock.unlock()

            guard let writer, let outputURL else {
                continuation.resume(throwing: AppError.captureFailed("沒有可儲存的擷取檔。"))
                return
            }
            if writer.status == .unknown {
                writer.cancelWriting()
                continuation.resume(throwing: AppError.captureFailed("沒有寫入任何畫面。"))
                return
            }
            if writer.status == .failed {
                continuation.resume(throwing: AppError.captureFailed(Self.describe(writer.error)))
                return
            }
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            writer.finishWriting {
                if writer.status == .completed {
                    continuation.resume(returning: outputURL)
                } else {
                    continuation.resume(throwing: AppError.captureFailed(Self.describe(writer.error)))
                }
            }
        }
        teardownWriter()
        let mixedURL = await mixCapturedAudio(into: finishedURL)
        await MainActor.run {
            phase = .ready
        }
        await startPreview()
        return (mixedURL, duration)
    }

    func cancelWithoutSaving() async {
        recording = false
        paused = false
        elapsedTimer?.invalidate()
        stopMicrophone()
        await stopActiveStream()
        await closeSystemAudioFile()
        if let audioURL = systemAudioURL {
            systemAudioURL = nil
            try? FileManager.default.removeItem(at: audioURL)
        }
        if let micURL {
            self.micURL = nil
            try? FileManager.default.removeItem(at: micURL)
        }
        writerLock.lock()
        writer?.cancelWriting()
        let url = outputURL
        writerLock.unlock()
        teardownWriter()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        await MainActor.run {
            phase = permission.screenGranted ? .ready : .idle
            elapsed = 0
        }
    }

    // MARK: - Stream

    private func installStream() async throws {
        let wantsAudio = includeSystemAudio
        let displayID = selectedDisplayID
        if wantsAudio {
            do {
                try await openStream(displayID: displayID, captureAudio: true)
                await MainActor.run {
                    if hint == Self.displayWithoutAudioHint {
                        hint = Self.defaultHint
                    }
                }
                return
            } catch {
                try await openStream(displayID: displayID, captureAudio: false)
                await MainActor.run { hint = Self.displayWithoutAudioHint }
                return
            }
        }
        try await openStream(displayID: displayID, captureAudio: false)
    }

    private func openStream(displayID: CGDirectDisplayID?, captureAudio: Bool) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let displayID = displayID ?? content.displays.first?.displayID,
              let display = content.displays.first(where: { $0.displayID == displayID })
        else {
            throw AppError.captureFailed("找不到可擷取的顯示器。")
        }

        let size = Self.nativePixelSize(for: display)
        let fps = Self.captureFrameRate(for: display.displayID)
        captureFPS = fps
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        config.queueDepth = 8
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.capturesAudio = captureAudio
        if #available(macOS 14.0, *) {
            config.captureResolution = .best
            config.colorSpaceName = CGColorSpace.sRGB
        }
        if #available(macOS 13.0, *) {
            config.sampleRate = 48000
            config.channelCount = 2
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        activeStream = stream
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            if captureAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            }
            try await startStream(stream)
            self.stream = stream
            streamDisplayID = display.displayID
            streamCapturesAudio = captureAudio
        } catch {
            if activeStream === stream {
                activeStream = nil
            }
            await stopStream(stream)
            throw error
        }
    }

    private static func nativePixelSize(for display: SCDisplay) -> (width: Int, height: Int) {
        let wide = Int(CGDisplayPixelsWide(display.displayID))
        let high = Int(CGDisplayPixelsHigh(display.displayID))
        if wide > 1, high > 1 {
            return evenPixelSize(width: wide, height: high)
        }
        var scale: CGFloat = 2
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  CGDirectDisplayID(truncating: number) == display.displayID else { continue }
            scale = screen.backingScaleFactor
            break
        }
        return evenPixelSize(
            width: Int((CGFloat(display.width) * scale).rounded()),
            height: Int((CGFloat(display.height) * scale).rounded())
        )
    }

    private static func evenPixelSize(width: Int, height: Int) -> (width: Int, height: Int) {
        (max(2, width / 2 * 2), max(2, height / 2 * 2))
    }

    /// ScreenCaptureKit will not deliver frames faster than this. ProMotion
    /// reports 0, so those displays record at 60. The saved file keeps the
    /// timestamps of the frames that actually arrive.
    private static func captureFrameRate(for displayID: CGDirectDisplayID) -> Int32 {
        var rate = 60.0
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            let refresh = mode.refreshRate
            if refresh >= 30 { rate = refresh }
        }
        return Int32(min(60, max(30, rate.rounded())))
    }

    private func startStream(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func stopStream(_ stream: SCStream) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stream.stopCapture { _ in
                continuation.resume()
            }
        }
    }

    private func prepareWriter(url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writerLock.lock()
        self.writer = writer
        self.videoInput = nil
        self.pixelAdaptor = nil
        self.audioInput = nil
        self.outputURL = url
        self.sessionStarted = false
        self.sessionStart = .zero
        self.lastVideoPTS = .invalid
        self.lastAudioPTS = .invalid
        self.retainedVideo = nil
        self.audioWaitStarted = nil
        self.audioConverter = nil
        self.audioOutputFormat = nil
        writerLock.unlock()
    }

    private func startTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.startedAt, !self.paused else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let startedAt = self.startedAt, !self.paused else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
        RunLoop.main.add(elapsedTimer!, forMode: .common)
    }

    private func startMicrophone() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.observeLevel(buffer)
            self.appendMicrophone(buffer)
        }
        try engine.start()
        audioEngine = engine
    }

    private func stopMicrophone() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFileLock.lock()
        micFile = nil
        audioFileLock.unlock()
    }

    private func observeLevel(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?.pointee else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }
        var sum: Float = 0
        for i in 0..<frameLength {
            let s = channel[i]
            sum += s * s
        }
        let rms = sqrt(sum / Float(frameLength))
        publishLevel(min(1, rms * 8))
    }

    private func teardownWriter() {
        writerLock.lock()
        writer = nil
        videoInput = nil
        pixelAdaptor = nil
        audioInput = nil
        outputURL = nil
        sessionStarted = false
        sessionStart = .zero
        lastVideoPTS = .invalid
        lastAudioPTS = .invalid
        retainedVideo = nil
        audioWaitStarted = nil
        audioConverter = nil
        audioOutputFormat = nil
        writerLock.unlock()
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        updatePreview(from: sampleBuffer)
        guard recording, !paused, isRecordableVideoFrame(sampleBuffer) else { return }
        writerLock.lock()
        defer { writerLock.unlock() }
        guard let writer, let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if writer.status == .failed {
            reportWriterFailure(writer.error)
            return
        }
        if !sessionStarted {
            attachVideoInput(for: pixel)
            let pts = monotonicVideoPTS(from: sampleBuffer)
            beginSession(at: pts)
            guard sessionStarted, let videoInput, let adaptor = pixelAdaptor, videoInput.isReadyForMoreMediaData else { return }
            if adaptor.append(pixel, withPresentationTime: pts) {
                lastVideoPTS = pts
            } else {
                reportWriterFailure(writer.error)
            }
            return
        }
        guard writer.status == .writing, let videoInput, let adaptor = pixelAdaptor, videoInput.isReadyForMoreMediaData else { return }
        let pts = monotonicVideoPTS(from: sampleBuffer)
        if adaptor.append(pixel, withPresentationTime: pts) {
            lastVideoPTS = pts
        } else if writer.status == .failed {
            reportWriterFailure(writer.error)
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        updateAudioLevel(from: sampleBuffer)
        guard recording, !paused, includeSystemAudio, streamCapturesAudio else { return }
        guard let buffer = floatBuffer(from: sampleBuffer) else { return }
        write(buffer, kind: .system)
    }

    private func appendMicrophone(_ buffer: AVAudioPCMBuffer) {
        guard recording, !paused, includeMicrophone else { return }
        guard let normalized = normalizedMicrophoneBuffer(buffer) else { return }
        write(normalized, kind: .microphone)
    }

    private enum AudioKind {
        case system
        case microphone
    }

    private func write(_ buffer: AVAudioPCMBuffer, kind: AudioKind) {
        audioFileLock.lock()
        defer { audioFileLock.unlock() }
        switch kind {
        case .system:
            if systemAudioFile == nil {
                guard let outputURL else { return }
                let url = outputURL.deletingPathExtension().appendingPathExtension("sys.caf")
                guard let file = Self.audioFile(at: url, format: buffer.format) else { return }
                systemAudioFile = file
                systemAudioURL = url
            }
            try? systemAudioFile?.write(from: buffer)
        case .microphone:
            if micFile == nil {
                guard let outputURL else { return }
                let url = outputURL.deletingPathExtension().appendingPathExtension("mic.caf")
                guard let file = Self.audioFile(at: url, format: buffer.format) else { return }
                micFile = file
                micURL = url
            }
            try? micFile?.write(from: buffer)
        }
    }

    private static func audioFile(at url: URL, format: AVAudioFormat) -> AVAudioFile? {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        return try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
    }

    private func isRecordableVideoFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return false }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachment = attachments.first else { return true }
        let raw = (attachment[.status] as? NSNumber)?.intValue ?? attachment[.status] as? Int
        guard let raw, let status = SCFrameStatus(rawValue: raw) else { return true }
        return status == .complete || status == .idle
    }

    private func monotonicVideoPTS(from sampleBuffer: CMSampleBuffer) -> CMTime {
        let raw = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let step = CMTime(value: 1, timescale: captureFPS)
        if !sessionStarted {
            return raw.isValid ? raw : .zero
        }
        if raw.isValid, !lastVideoPTS.isValid || CMTimeCompare(raw, lastVideoPTS) > 0 {
            return raw
        }
        if lastVideoPTS.isValid {
            return CMTimeAdd(lastVideoPTS, step)
        }
        return step
    }

    private func attachVideoInput(for pixel: CVPixelBuffer) {
        guard videoInput == nil, let writer, writer.status == .unknown else { return }
        let width = CVPixelBufferGetWidth(pixel)
        let height = CVPixelBufferGetHeight(pixel)
        guard width > 1, height > 1, width.isMultiple(of: 2), height.isMultiple(of: 2) else { return }
        let fps = captureFPS
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.videoBitrate(width: width, height: height, fps: fps),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return }
        writer.add(input)
        videoInput = input
        pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
    }

    private func beginSession(at pts: CMTime) {
        guard let writer, writer.status == .unknown, videoInput != nil else { return }
        let start = pts.isValid ? pts : .zero
        writer.startWriting()
        guard writer.status == .writing else {
            reportWriterFailure(writer.error)
            return
        }
        writer.startSession(atSourceTime: start)
        sessionStart = start
        sessionStarted = true
    }

    private func reportWriterFailure(_ error: Error?) {
        let message = "擷取失敗：\(Self.describe(error))"
        recording = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.elapsedTimer?.invalidate()
            self.lastError = message
            self.phase = .failed(message)
        }
    }

    private func floatBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM else { return nil }
        let channels = Int(asbd.mChannelsPerFrame)
        let frames = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        guard channels > 0, frames > 0 else { return nil }

        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &needed,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard needed > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: raw.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: needed,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &block
        )
        guard status == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.mSampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ), let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
           let destination = output.floatChannelData?.pointee else { return nil }
        output.frameLength = AVAudioFrameCount(frames)

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bits = Int(asbd.mBitsPerChannel)
        if isFloat, bits == 32, nonInterleaved {
            for channel in 0..<min(channels, buffers.count) {
                guard let data = buffers[channel].mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                let count = min(frames, Int(buffers[channel].mDataByteSize) / MemoryLayout<Float>.size)
                for index in 0..<count {
                    destination[index * channels + channel] = samples[index]
                }
            }
        } else if isFloat, bits == 32, let data = buffers.first?.mData {
            let count = min(frames * channels, Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size)
            data.withMemoryRebound(to: Float.self, capacity: count) { source in
                destination.update(from: source, count: count)
            }
        } else if bits == 16, let data = buffers.first?.mData {
            let count = min(frames * channels, Int(buffers[0].mDataByteSize) / MemoryLayout<Int16>.size)
            data.withMemoryRebound(to: Int16.self, capacity: count) { source in
                for index in 0..<count {
                    destination[index] = Float(source[index]) / Float(Int16.max)
                }
            }
        } else {
            return nil
        }
        return output
    }

    private func normalizedMicrophoneBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format.commonFormat == .pcmFormatFloat32, buffer.format.isInterleaved {
            return buffer
        }
        guard let destination = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.format.sampleRate,
            channels: buffer.format.channelCount,
            interleaved: true
        ) else { return nil }
        if micConverter == nil || micFormat?.sampleRate != destination.sampleRate || micFormat?.channelCount != destination.channelCount {
            guard let converter = AVAudioConverter(from: buffer.format, to: destination) else { return nil }
            micConverter = converter
            micFormat = destination
        }
        guard let converter = micConverter, let outputFormat = micFormat,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: buffer.frameCapacity) else { return nil }
        var conversionError: NSError?
        var supplied = false
        converter.convert(to: output, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }

    private func closeSystemAudioFile() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            audioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                self.audioFileLock.lock()
                self.systemAudioFile = nil
                self.audioFileLock.unlock()
                continuation.resume()
            }
        }
    }

    private func mixCapturedAudio(into video: URL) async -> URL {
        await closeSystemAudioFile()
        let systemURL = systemAudioURL
        let microphoneURL = micURL
        systemAudioURL = nil
        micURL = nil
        let tracks = [systemURL, microphoneURL].compactMap { url -> URL? in
            guard let url else { return nil }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 4_096 else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return url
        }
        guard !tracks.isEmpty, let ffmpeg = VideoThumbnail.ffmpegExecutable(preferred: ffmpegPath) else {
            if includeSystemAudio || includeMicrophone {
                audioMixNote = "畫面已存好。這次沒有收進聲音。"
            }
            return video
        }
        let muxed = video.deletingLastPathComponent().appendingPathComponent(video.deletingPathExtension().lastPathComponent + "-mix.mov")
        var arguments = ["-y", "-i", video.path]
        tracks.forEach { arguments += ["-i", $0.path] }
        if tracks.count == 1 {
            arguments += ["-map", "0:v:0", "-map", "1:a:0"]
        } else {
            let inputs = (1...tracks.count).map { "[\($0):a]" }.joined()
            arguments += [
                "-filter_complex",
                "\(inputs)amix=inputs=\(tracks.count):duration=longest:normalize=0[a]",
                "-map", "0:v:0",
                "-map", "[a]"
            ]
        }
        arguments += ["-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", muxed.path]
        let result = try? await ProcessRunner.run(
            executable: ffmpeg,
            arguments: arguments,
            timeout: 60 * 30
        )
        tracks.forEach { try? FileManager.default.removeItem(at: $0) }
        guard result?.exitCode == 0, FileManager.default.fileExists(atPath: muxed.path) else {
            try? FileManager.default.removeItem(at: muxed)
            audioMixNote = "畫面已存好。聲音沒有併進檔案。"
            return video
        }
        try? FileManager.default.removeItem(at: video)
        do {
            try FileManager.default.moveItem(at: muxed, to: video)
            return video
        } catch {
            return muxed
        }
    }

    private static func describe(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "無法完成操作" }
        var parts = [error.localizedDescription, "\(error.domain) \(error.code)"]
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("\(underlying.domain) \(underlying.code)")
        }
        return parts.joined(separator: " · ")
    }

    private static func captureMessage(_ error: Error) -> String {
        if let appError = error as? AppError {
            return appError.localizedChinese
        }
        return "擷取失敗：\(describe(error))"
    }

    private static func videoBitrate(width: Int, height: Int, fps: Int32) -> Int {
        let pixels = width * height
        let base: Int
        if pixels >= 8_000_000 { base = 40_000_000 }
        else if pixels >= 3_500_000 { base = 24_000_000 }
        else if pixels >= 2_000_000 { base = 16_000_000 }
        else { base = 8_000_000 }
        return fps >= 50 ? base * 3 / 2 : base
    }

    private func updatePreview(from sampleBuffer: CMSampleBuffer) {
        previewLock.lock()
        let busy = previewInFlight
        if !busy { previewInFlight = true }
        previewLock.unlock()
        guard !busy else { return }
        previewCounter += 1
        let stride = recording ? 8 : 3
        guard previewCounter % stride == 0, CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
            previewLock.lock()
            previewInFlight = false
            previewLock.unlock()
            return
        }
        let retained = Unmanaged.passRetained(sampleBuffer)
        previewQueue.async { [weak self] in
            let buffer = retained.takeUnretainedValue()
            let image = self?.previewImage(from: buffer)
            retained.release()
            self?.previewLock.lock()
            self?.previewInFlight = false
            self?.previewLock.unlock()
            guard let image else { return }
            DispatchQueue.main.async { [weak self] in
                self?.previewImage = image
            }
        }
    }

    private func previewImage(from sampleBuffer: CMSampleBuffer) -> NSImage? {
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let ci = CIImage(cvImageBuffer: pixel)
        let extent = ci.extent
        guard extent.width > 1, extent.height > 1 else { return nil }
        let scale = min(1, 960 / extent.width)
        let scaled = scale < 1 ? ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : ci
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func updateAudioLevel(from sampleBuffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard let dataPointer, length > 1 else { return }
        let samples = UnsafeRawPointer(dataPointer).bindMemory(to: Int16.self, capacity: length / 2)
        let count = min(512, length / 2)
        var sum: Float = 0
        for i in 0..<count {
            let v = Float(samples[i]) / Float(Int16.max)
            sum += v * v
        }
        let rms = sqrt(sum / Float(max(count, 1)))
        publishLevel(min(1, rms * 4))
    }

    /// Sample callbacks arrive on capture queues. Coalesce them so SwiftUI is not
    /// republished on every audio buffer.
    private func publishLevel(_ level: Float) {
        levelLock.lock()
        pendingLevel = level
        let shouldSchedule = !levelPublishQueued
        if shouldSchedule { levelPublishQueued = true }
        levelLock.unlock()
        guard shouldSchedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.levelLock.lock()
            let value = self.pendingLevel
            self.levelPublishQueued = false
            self.levelLock.unlock()
            let elapsed = Date().timeIntervalSince(self.lastLevelPublish)
            guard elapsed >= 0.08, abs(self.audioLevel - value) > 0.02 else { return }
            self.lastLevelPublish = Date()
            self.audioLevel = value
        }
    }

    private static func screenName(for id: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               CGDirectDisplayID(truncating: number) == id {
                return screen.localizedName
            }
        }
        return "顯示器 \(id)"
    }
}

extension CapturePipeline: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard stream === activeStream, CMSampleBufferIsValid(sampleBuffer) else { return }
        switch type {
        case .screen:
            appendVideo(sampleBuffer)
        case .audio:
            appendAudio(sampleBuffer)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, stream === self.activeStream else { return }
            self.activeStream = nil
            self.stream = nil
            self.streamDisplayID = nil
            let canDropAudio = self.streamCapturesAudio && !self.sessionStarted && !self.attemptedAudioRecovery
            self.streamCapturesAudio = false
            if canDropAudio {
                self.attemptedAudioRecovery = true
                self.hint = Self.displayWithoutAudioHint
                self.lastError = nil
                Task { await self.reopenWithoutSystemAudio() }
                return
            }
            self.recording = false
            self.elapsedTimer?.invalidate()
            let message = "擷取失敗：\(Self.describe(error))。若畫面上有授權視窗，請先允許，再重新開始擷取。"
            self.lastError = message
            self.phase = .failed(message)
        }
    }

    private func reopenWithoutSystemAudio() async {
        do {
            try await openStream(displayID: selectedDisplayID, captureAudio: false)
            await MainActor.run {
                hint = Self.displayWithoutAudioHint
                lastError = nil
                if recording {
                    phase = .recording
                } else if phase != .saving {
                    phase = .ready
                }
            }
        } catch {
            await MainActor.run {
                recording = false
                elapsedTimer?.invalidate()
                let message = Self.captureMessage(error)
                lastError = message
                phase = .failed(message)
            }
        }
    }
}

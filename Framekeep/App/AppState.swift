import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    @Published var selected: SidebarDestination = .home
    @Published var urlText: String = ""
    @Published var isProbing = false
    @Published var showingPicker = false
    @Published var showingSetup = false
    @Published var banner: String?
    @Published var pickerPreset: DefaultFormatPreset
    @Published var pickerCustom: MediaFormat?
    @Published var activeProbe: ProbeResult?
    @Published var activeJobID: UUID?
    @Published var renameTarget: MediaItem?
    @Published var renameText: String = ""
    @Published var trimTarget: MediaItem?
    @Published var trimRequest = 0

    let settings: AppSettings
    let toolchain: ToolchainDetector
    let queue: DownloadQueueService
    let library: LibraryService
    let capture: CapturePipeline
    let router = CapabilityRouter()

    private var cancellables = Set<AnyCancellable>()
    private var clipboardTimer: Timer?
    private var bootstrapped = false
    private var deferredPage: String?
    private var lastExternalKey = ""
    private var lastExternalAt = Date.distantPast
    private var closeMainAfterTrim = false
    private var lastTrimPath = ""
    private var lastTrimAt = Date.distantPast
    private var ingestingText: String?
    private var followupText: String?
    private var ignoreNextURLChange = false

    init() {
        let settings = AppSettings()
        self.settings = settings
        pickerPreset = settings.defaultFormat
        let store: SQLiteStore
        do {
            try AppPaths.ensureStandardLayout(root: settings.moviesRootURL)
            store = try SQLiteStore(fileURL: AppPaths.databaseFile)
        } catch {
            AppLog.error("store init failed: \(error.localizedDescription)")
            store = try! SQLiteStore(fileURL: AppPaths.databaseFile)
        }
        toolchain = ToolchainDetector()
        queue = DownloadQueueService(store: JobStore(db: store), settings: settings)
        library = LibraryService(db: store, settings: settings)
        capture = CapturePipeline()
        capture.includeMicrophone = settings.includeMicrophoneByDefault

        BrowserLinkCenter.shared.bind { [weak self] url in
            Task { @MainActor in
                self?.acceptExternalURL(url)
            }
        }
        TrimFileCenter.shared.bind { [weak self] request in
            Task { @MainActor in
                self?.openTrim(files: request.urls, replacesMainWindow: request.replacesMainWindow)
            }
        }

        settings.$watchClipboard
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.configureClipboardWatch(enabled)
            }
            .store(in: &cancellables)
    }

    func bootstrap() async {
        await toolchain.refresh(settings: settings)
        showingSetup = !toolchain.status.isReady
        capture.refreshPermissions()
        BrowserBridge.install()
        bootstrapped = true
        if let page = deferredPage {
            deferredPage = nil
            urlText = page
            selected = .home
            await continueIngest(source: .browser)
        }
    }

    func acceptExternalURL(_ url: URL) {
        guard let page = BrowserLink.pageURL(from: url) else { return }
        let now = Date()
        if page == lastExternalKey, now.timeIntervalSince(lastExternalAt) < 2 { return }
        lastExternalKey = page
        lastExternalAt = now
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
        selected = .home
        urlText = page
        banner = nil
        if bootstrapped {
            Task { await continueIngest(source: .browser) }
        } else {
            deferredPage = page
        }
    }

    func pasteFromClipboard() {
        if let text = URLIngestService.pasteboardURLString() {
            urlText = text
            banner = nil
        } else {
            banner = "剪貼簿裡沒有可用的連結。"
        }
    }

    func consumeURLAutostartSuppression() -> Bool {
        let suppressed = ignoreNextURLChange
        ignoreNextURLChange = false
        return suppressed
    }

    func continueIngest(source: IngestSource = .manual) async {
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if ingestingText != nil {
            if !text.isEmpty, text != ingestingText {
                followupText = text
            }
            return
        }
        ingestingText = text
        await performIngest(source: source)
        let done = ingestingText
        ingestingText = nil
        if let next = followupText, next != done {
            followupText = nil
            ignoreNextURLChange = true
            urlText = next
            await continueIngest(source: source)
        } else {
            followupText = nil
        }
    }

    private func performIngest(source: IngestSource) async {
        banner = nil
        guard toolchain.status.isReady, let ytdlp = toolchain.status.ytdlpURL else {
            showingSetup = true
            return
        }
        do {
            var request = try URLIngestService.makeRequest(from: urlText, source: source)
            isProbing = true
            let expanded = await URLIngestService.expandIfShort(request.url)
            if expanded != request.url {
                request = IngestRequest(id: request.id, url: expanded, source: source, originalText: request.originalText)
                ignoreNextURLChange = true
                urlText = expanded.absoluteString
            }
            let job = DownloadJob.probing(request: request)
            queue.insertProbing(job)
            activeJobID = job.id
            let decision = await router.route(
                request: request,
                cookies: settings.cookieFileURL,
                ytdlp: ytdlp,
                ffmpeg: toolchain.status.ffmpegURL
            )
            isProbing = false
            if let probe = decision.probe, decision.capability == .downloadable {
                queue.updateAfterProbe(job.id, probe: probe)
                activeProbe = probe
                let preset = settings.defaultFormat == .custom ? DefaultFormatPreset.best : settings.defaultFormat
                pickerPreset = preset
                pickerCustom = probe.recommendedFormat(for: preset)
                enqueueCurrentPick()
                ignoreNextURLChange = true
                urlText = ""
            } else {
                let error = decision.error ?? .unsupported
                queue.markFailed(job.id, error: error)
                banner = decision.statusChinese
            }
        } catch let error as AppError {
            isProbing = false
            banner = error.localizedChinese
        } catch {
            isProbing = false
            banner = AppError.probeFailed(error.localizedDescription).localizedChinese
        }
    }

    func enqueueCurrentPick() {
        guard let probe = activeProbe,
              let id = activeJobID,
              let ytdlp = toolchain.status.ytdlpURL
        else { return }
        queue.enqueueSelected(
            id: id,
            preset: pickerPreset,
            custom: pickerCustom,
            probe: probe,
            ytdlp: ytdlp,
            ffmpeg: toolchain.status.ffmpegURL,
            library: library
        )
        showingPicker = false
        selected = .home
        banner = nil
    }

    func switchToCaptureFromPicker() {
        if let id = activeJobID, let job = queue.jobs.first(where: { $0.id == id }) {
            queue.cancel(job)
        }
        showingPicker = false
        selected = .capture
    }

    func switchToCapture(from job: DownloadJob) {
        ignoreNextURLChange = true
        urlText = job.url.absoluteString
        selected = .capture
        banner = "改用擷取：請在瀏覽器播放內容後按錄製。"
    }

    func retry(_ job: DownloadJob) {
        guard let ytdlp = toolchain.status.ytdlpURL else {
            showingSetup = true
            return
        }
        queue.retry(job, ytdlp: ytdlp, ffmpeg: toolchain.status.ffmpegURL, library: library)
    }

    func pause(_ job: DownloadJob) {
        queue.pause(job)
    }

    func resume(_ job: DownloadJob) {
        guard let ytdlp = toolchain.status.ytdlpURL else {
            showingSetup = true
            return
        }
        queue.resume(job, ytdlp: ytdlp, ffmpeg: toolchain.status.ffmpegURL, library: library)
    }

    func cancel(_ job: DownloadJob) {
        queue.cancel(job)
    }

    func removeFromQueue(_ job: DownloadJob) {
        removeFromQueue([job.id])
    }

    func removeFromQueue(_ ids: Set<UUID>) {
        let targets = queue.jobs.filter { ids.contains($0.id) }
        for job in targets {
            queue.remove(job)
            if activeJobID == job.id {
                showingPicker = false
                activeJobID = nil
            }
        }
    }

    func openTrim(files: [URL], replacesMainWindow: Bool = false) {
        let videos = files.filter(VideoFiles.isVideo)
        guard let first = videos.first else {
            banner = "請選擇影片檔。"
            return
        }
        if replacesMainWindow {
            closeMainAfterTrim = true
        }
        let now = Date()
        let sameFile = first.path == lastTrimPath && now.timeIntervalSince(lastTrimAt) < 1.5
        lastTrimPath = first.path
        lastTrimAt = now
        if !sameFile {
            trimTarget = MediaItem.importedFile(first)
        }
        trimRequest += 1
        NSApp.activate(ignoringOtherApps: true)
        if videos.count > 1 {
            banner = "已開啟第一個影片。一次剪接一個檔案。"
        }
    }

    func takeCloseMainAfterTrim() -> Bool {
        let value = closeMainAfterTrim
        closeMainAfterTrim = false
        return value
    }

    func chooseTrimVideo() {
        let panel = NSOpenPanel()
        panel.title = "選擇要剪接的影片"
        panel.prompt = "選擇"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                self.openTrim(files: [url])
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    func acceptTrimProviders(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let fileURL = item as? URL {
                    url = fileURL
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }
                guard let url else { return }
                DispatchQueue.main.async {
                    self.openTrim(files: [url])
                }
            }
        }
        return true
    }

    func startCapture() async {
        banner = nil
        await capture.startRecording(root: settings.moviesRootURL, ffmpegPath: settings.ffmpegPath)
    }

    func stopCapture() async {
        do {
            let result = try await capture.stopRecording()
            let title = activeProbe?.title ?? "螢幕擷取 \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
            _ = try library.commitCapture(
                title: title,
                file: result.url,
                duration: result.duration,
                sourceURL: URLIngestService.normalize(urlText)
            )
            selected = .library
            banner = capture.audioMixNote ?? "擷取已存進媒體庫。"
        } catch let error as AppError {
            banner = error.localizedChinese
        } catch {
            banner = AppError.captureFailed(error.localizedDescription).localizedChinese
        }
    }

    func importCookieFile() {
        let panel = NSOpenPanel()
        panel.title = "匯入 cookies.txt"
        panel.message = "只匯入你自己從瀏覽器匯出的 cookies.txt，不會讀取密碼。"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .data]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                self?.settings.applyImportedCookieFile(url)
                self?.banner = "已記住 cookie 檔路徑（內容不會寫進日誌）。"
            }
        }
    }

    func chooseMoviesRoot() {
        let panel = NSOpenPanel()
        panel.title = "選擇儲存位置"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                self?.settings.moviesRootPath = url.path
                try? AppPaths.ensureStandardLayout(root: url)
            }
        }
    }

    func chooseTool(title: String, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async { completion(url) }
        }
    }

    private func configureClipboardWatch(_ enabled: Bool) {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        guard enabled else { return }
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let text = URLIngestService.pasteboardURLString() else { return }
                self.ignoreNextURLChange = true
                self.urlText = text
            }
        }
        if let clipboardTimer {
            RunLoop.main.add(clipboardTimer, forMode: .common)
        }
    }
}

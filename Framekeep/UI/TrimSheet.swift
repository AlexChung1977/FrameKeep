import AVKit
import SwiftUI

struct TrimSheet: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var library: LibraryService
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: TrimSession

    init(item: MediaItem) {
        _session = StateObject(wrappedValue: TrimSession(item: item))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("剪接")
                    .font(FKFont.display(18, weight: .semibold))
                    .foregroundStyle(FKColor.paper)
                Spacer()
                GhostButton(title: "選擇影片") { app.chooseTrimVideo() }
            }
            Text(session.item.title)
                .font(FKFont.body(12))
                .foregroundStyle(FKColor.paperMuted)
                .lineLimit(1)
            Text("可以把別的影片拖進這個視窗。")
                .font(FKFont.body(11))
                .foregroundStyle(FKColor.paperFaint)

            ZStack {
                Color.black
                if session.isPlayingPreview {
                    PlayerHost(player: session.player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let image = session.scrubImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id(session.scrubRevision)
                }
                if !session.isPlayingPreview {
                    VStack {
                        HStack {
                            Text(session.scrubCaption.isEmpty ? "正在讀取預覽…" : session.scrubCaption)
                                .font(FKFont.body(11, weight: .medium))
                                .foregroundStyle(FKColor.paper)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.55))
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(8)
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 280)
            .layoutPriority(1)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("目前片段 起點 \(Self.clock(session.start))")
                    Spacer()
                    Text("終點 \(Self.clock(session.end))")
                }
                .font(FKFont.body(12))
                .foregroundStyle(FKColor.paperMuted)
                TrimRangeBar(
                    duration: sliderMax,
                    segments: session.segments.map { ($0.start, $0.end) },
                    selectedIndex: session.selectedIndex,
                    playhead: session.playhead,
                    onSelect: { session.selectSegment($0) },
                    onStart: { session.setStart($0, ffmpegPath: app.settings.ffmpegPath) },
                    onEnd: { session.setEnd($0, ffmpegPath: app.settings.ffmpegPath) },
                    onSeek: { session.preview(at: $0, ffmpegPath: app.settings.ffmpegPath) }
                )
                Text("共 \(session.segments.count) 段 · 合成後約 \(Self.clock(session.totalLength))")
                    .font(FKFont.body(12))
                    .foregroundStyle(FKColor.amber)
            }

            segmentList

            HStack {
                GhostButton(title: "設為起點") { session.setStartToPlayhead() }
                GhostButton(title: "設為終點") { session.setEndToPlayhead() }
                GhostButton(title: "播放目前段") {
                    session.playSelection(ffmpegPath: app.settings.ffmpegPath)
                }
                if session.segments.count > 1 {
                    GhostButton(title: "依序預覽") {
                        session.playAllSelections(ffmpegPath: app.settings.ffmpegPath)
                    }
                }
                Spacer()
            }

            TextField("輸出名稱", text: $session.outputTitle)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 6) {
                Text("輸出位置")
                    .font(FKFont.body(12, weight: .medium))
                    .foregroundStyle(FKColor.paperMuted)
                HStack {
                    TextField(defaultOutputDirectory.path, text: $settings.trimOutputDirectory)
                        .textFieldStyle(.roundedBorder)
                    AmberButton(title: "選擇…", prominent: false, action: chooseOutputFolder)
                    if !settings.trimOutputDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        GhostButton(title: "媒體庫") {
                            settings.trimOutputDirectory = ""
                        }
                    }
                }
                Text(outputLocationCaption)
                    .font(FKFont.body(11))
                    .foregroundStyle(FKColor.paperFaint)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Toggle("精確對到影格（重新編碼，較慢）", isOn: $session.accurate)
                .toggleStyle(.checkbox)
                .foregroundStyle(FKColor.paper)
                .disabled(session.exporting)
            Text(session.accurate
                 ? "會重新編碼，起點和終點較準。多段會依序剪下再合成一個檔案。"
                 : "直接裁切，速度快。起點可能對到附近的關鍵幀。多段會依序剪下再合成一個檔案。")
                .font(FKFont.body(11))
                .foregroundStyle(FKColor.paperFaint)

            if session.exporting {
                ProgressView(value: session.progress)
                    .tint(FKColor.amber)
            }
            if let error = session.error {
                Text(error)
                    .font(FKFont.body(12))
                    .foregroundStyle(FKColor.danger)
                    .lineLimit(3)
            }

            HStack {
                Spacer()
                GhostButton(title: "取消") {
                    session.cancelExport()
                    dismiss()
                }
                AmberButton(title: session.exporting ? "剪接中…" : "輸出到媒體庫", enabled: canExport) {
                    Task { await export() }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FKColor.graphite)
        .preferredColorScheme(.dark)
        .task {
            session.observePlayback()
            await session.loadDuration(using: library)
            await session.loadPlaybackMode()
            session.scheduleScrub(at: session.start, label: "起點", ffmpegPath: app.settings.ffmpegPath)
        }
        .onDisappear { session.stop() }
    }

    private var segmentList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("片段")
                    .font(FKFont.body(12, weight: .medium))
                    .foregroundStyle(FKColor.paperMuted)
                Spacer()
                GhostButton(title: "新增片段") {
                    session.addSegment(ffmpegPath: app.settings.ffmpegPath)
                }
                .disabled(session.exporting)
            }
            ForEach(Array(session.segments.enumerated()), id: \.element.id) { index, segment in
                HStack(spacing: 8) {
                    Button {
                        session.selectSegment(index)
                        session.preview(at: segment.start, ffmpegPath: app.settings.ffmpegPath)
                    } label: {
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(FKFont.body(11, weight: .semibold))
                                .foregroundStyle(index == session.selectedIndex ? FKColor.graphite : FKColor.paperMuted)
                                .frame(width: 18, height: 18)
                                .background(index == session.selectedIndex ? FKColor.amber : Color.white.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            Text("\(Self.clock(segment.start)) – \(Self.clock(segment.end))")
                                .font(FKFont.body(12))
                                .foregroundStyle(FKColor.paper)
                            Text(Self.clock(segment.length))
                                .font(FKFont.body(11))
                                .foregroundStyle(FKColor.paperMuted)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(session.exporting)

                    if session.segments.count > 1 {
                        GhostButton(title: "刪除") {
                            session.removeSegment(at: index, ffmpegPath: app.settings.ffmpegPath)
                        }
                        .disabled(session.exporting)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var canExport: Bool {
        !session.exporting
            && session.item.exists
            && session.segments.contains(where: { $0.length >= 0.1 })
    }

    private var sliderMax: Double {
        max(session.duration, 0.2)
    }

    private var defaultOutputDirectory: URL {
        AppPaths.datedLibraryDirectory(root: settings.moviesRootURL)
    }

    private var resolvedOutputDirectory: URL {
        let raw = settings.trimOutputDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return defaultOutputDirectory }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    private var outputLocationCaption: String {
        "多段會合成為單一檔案，存到 \(resolvedOutputDirectory.path)，並出現在媒體庫。"
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "選擇剪接輸出位置"
        panel.prompt = "選擇"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = resolvedOutputDirectory
        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                settings.trimOutputDirectory = url.path
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: apply)
        } else {
            panel.begin(completionHandler: apply)
        }
    }

    private func export() async {
        session.exporting = true
        session.progress = 0
        session.error = nil
        session.player.pause()
        do {
            let segments = session.segments.filter { $0.length >= 0.1 }
            let file = try await VideoTrimmer.export(
                VideoTrimmer.Request(
                    source: session.item.fileURL,
                    segments: segments,
                    ffmpegPath: app.settings.ffmpegPath,
                    accurate: session.accurate
                ),
                onStart: { handle in
                    Task { @MainActor in
                        session.exportHandle = handle
                    }
                }
            ) { fraction in
                Task { @MainActor in
                    session.progress = fraction
                }
            }
            let duration = segments.reduce(0) { $0 + $1.length }
            let saved = try library.commitTrim(
                of: session.item,
                file: file,
                title: session.outputTitle,
                duration: duration,
                directory: resolvedOutputDirectory
            )
            app.banner = "剪接已存到 \(saved.fileURL.deletingLastPathComponent().path)"
            dismiss()
        } catch {
            session.error = error.localizedDescription
            session.exporting = false
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

private struct TrimRangeBar: View {
    var duration: Double
    var segments: [(Double, Double)]
    var selectedIndex: Int
    var playhead: Double
    var onSelect: (Int) -> Void
    var onStart: (Double) -> Void
    var onEnd: (Double) -> Void
    var onSeek: (Double) -> Void

    @State private var drag: DragEdge?
    @State private var dragOrigin: Double = 0

    private enum DragEdge { case start, end }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let inset: CGFloat = 7
            let track = max(width - inset * 2, 1)
            let span = max(duration, 0.2)
            let playX = inset + track * CGFloat(min(max(playhead, 0), span) / span)
            let selected = segments.indices.contains(selectedIndex) ? segments[selectedIndex] : nil
            let startX = selected.map { inset + track * CGFloat(min(max($0.0, 0), span) / span) } ?? inset
            let endX = selected.map { inset + track * CGFloat(min(max($0.1, 0), span) / span) } ?? inset

            ZStack(alignment: .leading) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                let x = min(max(value.location.x - inset, 0), track)
                                let seconds = span * Double(x / track)
                                if let hit = hitSegment(at: seconds) {
                                    onSelect(hit)
                                }
                                onSeek(seconds)
                            }
                    )
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: 8)
                    .padding(.horizontal, inset)
                    .allowsHitTesting(false)

                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    let sX = inset + track * CGFloat(min(max(segment.0, 0), span) / span)
                    let eX = inset + track * CGFloat(min(max(segment.1, 0), span) / span)
                    Capsule()
                        .fill(index == selectedIndex ? FKColor.amber : FKColor.amber.opacity(0.35))
                        .frame(width: max(eX - sX, 4), height: 8)
                        .offset(x: sX)
                        .allowsHitTesting(false)
                }

                Rectangle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2, height: 18)
                    .offset(x: playX - 1)
                    .allowsHitTesting(false)

                if selected != nil {
                    handle
                        .position(x: startX, y: geo.size.height / 2)
                        .highPriorityGesture(dragGesture(.start, track: track, span: span))
                    handle
                        .position(x: endX, y: geo.size.height / 2)
                        .highPriorityGesture(dragGesture(.end, track: track, span: span))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 28)
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(FKColor.amber)
            .frame(width: 12, height: 22)
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(Color.white.opacity(0.85), lineWidth: 1)
            )
    }

    private func hitSegment(at seconds: Double) -> Int? {
        for (index, segment) in segments.enumerated().reversed() {
            if seconds >= segment.0 && seconds <= segment.1 {
                return index
            }
        }
        return nil
    }

    private func dragGesture(_ edge: DragEdge, track: CGFloat, span: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag != edge {
                    drag = edge
                    guard segments.indices.contains(selectedIndex) else { return }
                    dragOrigin = edge == .start ? segments[selectedIndex].0 : segments[selectedIndex].1
                }
                let next = dragOrigin + Double(value.translation.width / track) * span
                if edge == .start {
                    onStart(next)
                } else {
                    onEnd(next)
                }
            }
            .onEnded { _ in
                drag = nil
            }
    }
}

private struct PlayerHost: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}

@MainActor
final class TrimSession: ObservableObject {
    let item: MediaItem
    let player: AVPlayer
    @Published var duration: Double
    @Published var segments: [VideoTrimmer.Segment]
    @Published var selectedIndex: Int = 0
    @Published var playhead: Double = 0
    @Published var outputTitle: String
    @Published var accurate = false
    @Published var exporting = false
    @Published var progress: Double = 0
    @Published var error: String?
    @Published var scrubImage: NSImage?
    @Published var scrubCaption = ""
    @Published var scrubRevision = 0
    @Published var isPlayingPreview = false
    var exportHandle: ProcessRunner.Handle?

    private var timeToken: Any?
    private var playingSelection = false
    private var playQueue: [VideoTrimmer.Segment] = []
    private var activePlayEnd: Double?
    private var playToken = 0
    private var acceptPlaybackTime = false
    private var nativePlayback = true
    private var playbackModeLoaded = false
    private var proxyPlayback = false
    private var proxyOrigin: [(sourceStart: Double, length: Double)] = []
    private var proxyTask: Task<Void, Never>?
    private var proxyURL: URL?
    private var scrubRequested: Double?
    private var scrubLabel = "起點"
    private var scrubInFlight = false
    private var scrubGeneration = 0
    private var scrubStopped = false

    var start: Double {
        guard segments.indices.contains(selectedIndex) else { return 0 }
        return segments[selectedIndex].start
    }

    var end: Double {
        guard segments.indices.contains(selectedIndex) else { return 0 }
        return segments[selectedIndex].end
    }

    var totalLength: TimeInterval {
        segments.reduce(0) { $0 + $1.length }
    }

    init(item: MediaItem) {
        self.item = item
        let known = item.duration ?? 0
        duration = known
        let end = known > 0 ? known : 0
        segments = [VideoTrimmer.Segment(start: 0, end: end)]
        outputTitle = "\(item.title) 剪接"
        player = AVPlayer(url: item.fileURL)
    }

    func observePlayback() {
        guard timeToken == nil else { return }
        timeToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in
                guard let self, seconds.isFinite else { return }
                guard self.playingSelection, self.acceptPlaybackTime else { return }
                if self.proxyPlayback {
                    self.playhead = self.sourceTime(forProxy: seconds)
                    return
                }
                self.playhead = seconds
                guard let limit = self.activePlayEnd, seconds >= limit - 0.05 else { return }
                if let next = self.playQueue.first {
                    self.playQueue.removeFirst()
                    self.activePlayEnd = next.end
                    self.seekAndPlay(from: next.start)
                } else {
                    self.activePlayEnd = nil
                    self.player.pause()
                    self.playingSelection = false
                    self.acceptPlaybackTime = false
                }
            }
        }
    }

    func loadPlaybackMode() async {
        guard !playbackModeLoaded else { return }
        let asset = AVURLAsset(url: item.fileURL)
        nativePlayback = (try? await asset.load(.isPlayable)) ?? false
        playbackModeLoaded = true
    }

    func loadDuration(using library: LibraryService) async {
        guard let loaded = await library.readDuration(of: item.fileURL), loaded > 0.1 else { return }
        duration = loaded
        if segments.count == 1, segments[0].end <= 0 || segments[0].end > loaded {
            segments[0].end = loaded
        }
    }

    func selectSegment(_ index: Int) {
        guard segments.indices.contains(index) else { return }
        selectedIndex = index
    }

    func addSegment(ffmpegPath: String) {
        let span = duration > 0 ? duration : max(end, 1)
        let preferredStart = min(max(0, playhead), max(0, span - 0.1))
        var nextStart = preferredStart
        var nextEnd = min(span, preferredStart + max(1, span * 0.1))
        if nextEnd - nextStart < 0.1 {
            nextStart = max(0, span - 1)
            nextEnd = span
        }
        segments.append(VideoTrimmer.Segment(start: nextStart, end: nextEnd))
        selectedIndex = segments.count - 1
        scheduleScrub(at: nextStart, label: "起點", ffmpegPath: ffmpegPath)
    }

    func removeSegment(at index: Int, ffmpegPath: String) {
        guard segments.count > 1, segments.indices.contains(index) else { return }
        segments.remove(at: index)
        selectedIndex = min(selectedIndex, segments.count - 1)
        scheduleScrub(at: start, label: "起點", ffmpegPath: ffmpegPath)
    }

    func setStart(_ value: Double, ffmpegPath: String) {
        guard segments.indices.contains(selectedIndex) else { return }
        let next = min(max(0, value), max(0, segments[selectedIndex].end - 0.1))
        segments[selectedIndex].start = next
        playhead = next
        scheduleScrub(at: next, label: "起點", ffmpegPath: ffmpegPath)
    }

    func setEnd(_ value: Double, ffmpegPath: String) {
        guard segments.indices.contains(selectedIndex) else { return }
        let next = min(max(segments[selectedIndex].start + 0.1, value), duration > 0 ? duration : value)
        segments[selectedIndex].end = next
        playhead = next
        scheduleScrub(at: next, label: "終點", ffmpegPath: ffmpegPath)
    }

    func preview(at seconds: Double, ffmpegPath: String) {
        let limit = duration > 0 ? duration : seconds
        let next = min(max(0, seconds), limit)
        playhead = next
        scheduleScrub(at: next, label: "位置", ffmpegPath: ffmpegPath)
    }

    func setStartToPlayhead() {
        setStart(playhead, ffmpegPath: "")
    }

    func setEndToPlayhead() {
        setEnd(playhead, ffmpegPath: "")
    }

    func scheduleScrub(at seconds: Double, label: String, ffmpegPath: String) {
        if playingSelection || isPlayingPreview || proxyTask != nil {
            cancelPreviewPlayback()
        }
        player.pause()
        if nativePlayback {
            seek(to: seconds)
        }
        scrubRequested = seconds
        scrubLabel = label
        scrubCaption = "\(label) \(Self.clock(seconds))"
        guard !scrubInFlight else { return }
        scrubInFlight = true
        scrubGeneration += 1
        let generation = scrubGeneration
        let source = item.fileURL
        Task {
            defer {
                if generation == self.scrubGeneration {
                    self.scrubInFlight = false
                }
            }
            while generation == scrubGeneration, !scrubStopped {
                guard let target = scrubRequested else { break }
                let caption = "\(scrubLabel) \(Self.clock(target))"
                scrubRequested = nil
                let data = await VideoTrimmer.previewJPEG(url: source, seconds: target, ffmpegPath: ffmpegPath)
                guard generation == scrubGeneration, !scrubStopped else { return }
                if scrubRequested != nil { continue }
                if let data, let image = NSImage(data: data) {
                    scrubImage = image
                    scrubCaption = caption
                    scrubRevision += 1
                }
                if scrubRequested == nil { break }
            }
            if generation == scrubGeneration, scrubRequested != nil, !scrubStopped {
                scrubInFlight = false
                scheduleScrub(at: scrubRequested ?? seconds, label: scrubLabel, ffmpegPath: ffmpegPath)
            }
        }
    }

    func playSelection(ffmpegPath: String) {
        guard segments.indices.contains(selectedIndex) else { return }
        let segment = segments[selectedIndex]
        guard segment.length >= 0.1 else { return }
        startPreview(segments: [segment], ffmpegPath: ffmpegPath)
    }

    func playAllSelections(ffmpegPath: String) {
        let queue = segments.filter { $0.length >= 0.1 }
        guard !queue.isEmpty else { return }
        startPreview(segments: queue, ffmpegPath: ffmpegPath)
    }

    func cancelExport() {
        exportHandle?.terminate()
        exportHandle = nil
        exporting = false
    }

    func stop() {
        scrubStopped = true
        cancelPreviewPlayback()
        player.pause()
        if let proxyURL {
            try? FileManager.default.removeItem(at: proxyURL)
            self.proxyURL = nil
        }
        if let timeToken {
            player.removeTimeObserver(timeToken)
            self.timeToken = nil
        }
    }

    private func startPreview(segments queue: [VideoTrimmer.Segment], ffmpegPath: String) {
        Task {
            if !playbackModeLoaded {
                await loadPlaybackMode()
            }
            if nativePlayback {
                beginNativePlay(queue: queue)
            } else {
                beginProxyPlay(segments: queue, ffmpegPath: ffmpegPath)
            }
        }
    }

    private func beginNativePlay(queue: [VideoTrimmer.Segment]) {
        guard let first = queue.first else { return }
        cancelPreviewPlayback()
        restoreSourceItem()
        isPlayingPreview = true
        proxyPlayback = false
        proxyOrigin = []
        playingSelection = true
        playQueue = Array(queue.dropFirst())
        activePlayEnd = first.end
        seekAndPlay(from: first.start)
    }

    private func beginProxyPlay(segments queue: [VideoTrimmer.Segment], ffmpegPath: String) {
        cancelPreviewPlayback()
        isPlayingPreview = false
        proxyPlayback = false
        scrubCaption = "正在準備預覽…"
        let source = item.fileURL
        proxyTask = Task { @MainActor in
            let file = await VideoTrimmer.makePreview(url: source, segments: queue, ffmpegPath: ffmpegPath)
            guard !Task.isCancelled else {
                if let file { try? FileManager.default.removeItem(at: file) }
                return
            }
            guard let file else {
                scrubCaption = "無法預覽這個影片。"
                return
            }
            if let previous = proxyURL {
                try? FileManager.default.removeItem(at: previous)
            }
            proxyURL = file
            proxyOrigin = queue.map { (sourceStart: $0.start, length: $0.length) }
            player.replaceCurrentItem(with: AVPlayerItem(url: file))
            proxyPlayback = true
            playingSelection = true
            acceptPlaybackTime = true
            activePlayEnd = nil
            playQueue = []
            isPlayingPreview = true
            player.play()
        }
    }

    private func cancelPreviewPlayback() {
        playToken += 1
        acceptPlaybackTime = false
        playingSelection = false
        playQueue = []
        activePlayEnd = nil
        proxyTask?.cancel()
        proxyTask = nil
        scrubGeneration += 1
        scrubRequested = nil
        scrubInFlight = false
        isPlayingPreview = false
    }

    private func restoreSourceItem() {
        guard proxyURL != nil else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: item.fileURL))
    }

    private func sourceTime(forProxy seconds: Double) -> Double {
        var cursor = 0.0
        for part in proxyOrigin {
            if seconds <= cursor + part.length {
                return part.sourceStart + max(0, seconds - cursor)
            }
            cursor += part.length
        }
        if let last = proxyOrigin.last {
            return last.sourceStart + last.length
        }
        return seconds
    }

    private func seekAndPlay(from seconds: Double) {
        playToken += 1
        let token = playToken
        acceptPlaybackTime = false
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, finished, token == self.playToken, self.playingSelection else { return }
                self.acceptPlaybackTime = true
                self.player.play()
            }
        }
    }

    private func seek(to seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: CMTime(seconds: 0.2, preferredTimescale: 600), toleranceAfter: CMTime(seconds: 0.2, preferredTimescale: 600))
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}

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
            Text("剪接")
                .font(FKFont.display(18, weight: .semibold))
                .foregroundStyle(FKColor.paper)
            Text(session.item.title)
                .font(FKFont.body(12))
                .foregroundStyle(FKColor.paperMuted)
                .lineLimit(1)

            ZStack {
                PlayerHost(player: session.player)
                if let image = session.scrubImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                    VStack {
                        HStack {
                            Text(session.scrubCaption)
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
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 320)
            .layoutPriority(1)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("起點 \(Self.clock(session.start))")
                    Spacer()
                    Text("終點 \(Self.clock(session.end))")
                }
                .font(FKFont.body(12))
                .foregroundStyle(FKColor.paperMuted)
                TrimRangeBar(
                    duration: sliderMax,
                    start: session.start,
                    end: session.end,
                    playhead: session.playhead,
                    onStart: { session.setStart($0, ffmpegPath: app.settings.ffmpegPath) },
                    onEnd: { session.setEnd($0, ffmpegPath: app.settings.ffmpegPath) },
                    onSeek: { session.preview(at: $0, ffmpegPath: app.settings.ffmpegPath) }
                )
                Text("片段長度 \(Self.clock(max(0, session.end - session.start)))")
                    .font(FKFont.body(12))
                    .foregroundStyle(FKColor.amber)
            }

            HStack {
                GhostButton(title: "設為起點") { session.setStartToPlayhead() }
                GhostButton(title: "設為終點") { session.setEndToPlayhead() }
                GhostButton(title: "播放選段") { session.playSelection() }
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
                 ? "會重新編碼，起點和終點較準。"
                 : "直接裁切，速度快。起點可能對到附近的關鍵幀。")
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
            session.scheduleScrub(at: session.start, label: "起點", ffmpegPath: app.settings.ffmpegPath)
        }
        .onDisappear { session.stop() }
    }

    private var canExport: Bool {
        !session.exporting && session.end - session.start >= 0.1 && session.item.exists
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
        "檔案會存到 \(resolvedOutputDirectory.path)，並出現在媒體庫。"
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
            let file = try await VideoTrimmer.export(
                VideoTrimmer.Request(
                    source: session.item.fileURL,
                    start: session.start,
                    end: session.end,
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
            let duration = session.end - session.start
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
    var start: Double
    var end: Double
    var playhead: Double
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
            let startX = inset + track * CGFloat(min(max(start, 0), span) / span)
            let endX = inset + track * CGFloat(min(max(end, 0), span) / span)
            let playX = inset + track * CGFloat(min(max(playhead, 0), span) / span)
            ZStack(alignment: .leading) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                let x = min(max(value.location.x - inset, 0), track)
                                onSeek(span * Double(x / track))
                            }
                    )
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: 8)
                    .padding(.horizontal, inset)
                    .allowsHitTesting(false)
                Capsule()
                    .fill(FKColor.amber)
                    .frame(width: max(endX - startX, 4), height: 8)
                    .offset(x: startX)
                    .allowsHitTesting(false)
                Rectangle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2, height: 18)
                    .offset(x: playX - 1)
                    .allowsHitTesting(false)
                handle
                    .position(x: startX, y: geo.size.height / 2)
                    .highPriorityGesture(dragGesture(.start, track: track, span: span))
                handle
                    .position(x: endX, y: geo.size.height / 2)
                    .highPriorityGesture(dragGesture(.end, track: track, span: span))
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

    private func dragGesture(_ edge: DragEdge, track: CGFloat, span: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag != edge {
                    drag = edge
                    dragOrigin = edge == .start ? start : end
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
    @Published var start: Double = 0
    @Published var end: Double
    @Published var playhead: Double = 0
    @Published var outputTitle: String
    @Published var accurate = false
    @Published var exporting = false
    @Published var progress: Double = 0
    @Published var error: String?
    @Published var scrubImage: NSImage?
    @Published var scrubCaption = ""
    var exportHandle: ProcessRunner.Handle?

    private var timeToken: Any?
    private var playingSelection = false
    private var scrubRequested: Double?
    private var scrubLabel = "起點"
    private var scrubInFlight = false
    private var scrubStopped = false

    init(item: MediaItem) {
        self.item = item
        let known = item.duration ?? 0
        duration = known
        end = known > 0 ? known : 0
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
                self.playhead = seconds
                if self.playingSelection, seconds >= self.end {
                    self.player.pause()
                    self.playingSelection = false
                }
            }
        }
    }

    func loadDuration(using library: LibraryService) async {
        guard let loaded = await library.readDuration(of: item.fileURL), loaded > 0.1 else { return }
        duration = loaded
        if end <= 0 || end > loaded { end = loaded }
    }

    func setStart(_ value: Double, ffmpegPath: String) {
        let next = min(max(0, value), max(0, end - 0.1))
        start = next
        playhead = next
        scheduleScrub(at: next, label: "起點", ffmpegPath: ffmpegPath)
    }

    func setEnd(_ value: Double, ffmpegPath: String) {
        let next = min(max(start + 0.1, value), duration > 0 ? duration : value)
        end = next
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
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }
        setStart(seconds, ffmpegPath: "")
    }

    func setEndToPlayhead() {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }
        setEnd(seconds, ffmpegPath: "")
    }

    func scheduleScrub(at seconds: Double, label: String, ffmpegPath: String) {
        player.pause()
        playingSelection = false
        seek(to: seconds)
        scrubRequested = seconds
        scrubLabel = label
        scrubCaption = "\(label) \(Self.clock(seconds))"
        guard !scrubInFlight else { return }
        scrubInFlight = true
        let source = item.fileURL
        Task {
            while !scrubStopped, let target = scrubRequested {
                let caption = "\(scrubLabel) \(Self.clock(target))"
                scrubRequested = nil
                let data = await VideoTrimmer.previewJPEG(url: source, seconds: target, ffmpegPath: ffmpegPath)
                guard !scrubStopped else { break }
                if scrubRequested != nil { continue }
                if let data, let image = NSImage(data: data) {
                    scrubImage = image
                    scrubCaption = caption
                }
                if scrubRequested == nil { break }
            }
            scrubInFlight = false
            if scrubRequested != nil, !scrubStopped {
                scheduleScrub(at: scrubRequested ?? seconds, label: scrubLabel, ffmpegPath: ffmpegPath)
            }
        }
    }

    func playSelection() {
        scrubImage = nil
        playingSelection = true
        let target = CMTime(seconds: start, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.player.play()
            }
        }
    }

    func cancelExport() {
        exportHandle?.terminate()
        exportHandle = nil
        exporting = false
    }

    func stop() {
        scrubStopped = true
        player.pause()
        if let timeToken {
            player.removeTimeObserver(timeToken)
            self.timeToken = nil
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

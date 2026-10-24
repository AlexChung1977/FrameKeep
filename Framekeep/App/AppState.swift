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

    func continueIngest(source: IngestSource = .manual) async {
        banner = nil
        guard toolchain.status.isReady, let ytdlp = toolchain.status.ytdlpURL else {
            showingSetup = true
            return
        }
        do {
            var request = try URLIngestService.makeRequest(from: urlText, source: source)
            let expanded = await URLIngestService.expandIfShort(request.url)
            if expanded != request.url {
                request = IngestRequest(id: request.id, url: expanded, source: source, originalText: request.originalText)
                urlText = expanded.absoluteString
            }
            let job = DownloadJob.probing(request: request)
            queue.insertProbing(job)
            activeJobID = job.id
            isProbing = true
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
                pickerPreset = settings.defaultFormat
                pickerCustom = probe.recommendedFormat(for: settings.defaultFormat)
                showingPicker = true
            } else {
                let error = decision.error ?? .unsupported
                queue.markFailed(job.id, error: error)
                banner = decision.statusChinese
                if decision.suggestsCapture {
                    // Stay on Home with an honest status; user can jump to Capture.
                }
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
        selected = .queue
        banner = "已加入佇列。"
    }

    func switchToCaptureFromPicker() {
        if let id = activeJobID, let job = queue.jobs.first(where: { $0.id == id }) {
            queue.cancel(job)
        }
        showingPicker = false
        selected = .capture
    }

    func switchToCapture(from job: DownloadJob) {
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
                self.urlText = text
            }
        }
        if let clipboardTimer {
            RunLoop.main.add(clipboardTimer, forMode: .common)
        }
    }
}

import Combine
import Foundation

@MainActor
final class DownloadQueueService: ObservableObject {
    @Published private(set) var jobs: [DownloadJob] = []

    private let store: JobStore
    private let settings: AppSettings
    private let client = YtDlpClient()
    private let remuxer = FFmpegRemuxer()
    private var running: [UUID: Task<Void, Never>] = [:]
    private var handles: [UUID: ProcessRunner.Handle] = [:]
    private var pausedIDs = Set<UUID>()

    init(store: JobStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        reload()
        recoverInterrupted()
    }

    var latestJob: DownloadJob? { jobs.first }

    func reload() {
        do {
            jobs = try store.all()
        } catch {
            AppLog.error("job reload: \(error.localizedDescription)")
            jobs = []
        }
    }

    func insertProbing(_ job: DownloadJob) {
        upsert(job)
    }

    func updateAfterProbe(_ id: UUID, probe: ProbeResult) {
        guard var job = jobs.first(where: { $0.id == id }) else { return }
        job.title = probe.title
        job.webpageID = probe.webpageID
        job.host = probe.sourceHost
        job.state = .awaitingFormat
        job.updatedAt = Date()
        upsert(job)
    }

    func markFailed(_ id: UUID, error: AppError) {
        guard var job = jobs.first(where: { $0.id == id }) else { return }
        job.state = .failed
        job.failureKind = FailureKind.from(error)
        job.failureMessage = error.localizedChinese
        job.updatedAt = Date()
        upsert(job)
    }

    func enqueueSelected(
        id: UUID,
        preset: DefaultFormatPreset,
        custom: MediaFormat?,
        probe: ProbeResult,
        ytdlp: URL,
        ffmpeg: URL?,
        library: LibraryService
    ) {
        guard var job = jobs.first(where: { $0.id == id }) else { return }
        job.formatID = FormatSelector.ytDlpSelector(preset: preset, custom: custom)
        job.formatLabel = FormatSelector.label(preset: preset, custom: custom)
        job.title = probe.title
        job.webpageID = probe.webpageID
        job.host = probe.sourceHost
        job.state = .queued
        job.failureKind = nil
        job.failureMessage = nil
        job.updatedAt = Date()
        upsert(job)
        pump(ytdlp: ytdlp, ffmpeg: ffmpeg, library: library)
    }

    func retry(_ job: DownloadJob, ytdlp: URL, ffmpeg: URL?, library: LibraryService) {
        var next = job
        next.state = .queued
        next.progress = 0
        next.speed = nil
        next.eta = nil
        next.failureKind = nil
        next.failureMessage = nil
        next.updatedAt = Date()
        upsert(next)
        pump(ytdlp: ytdlp, ffmpeg: ffmpeg, library: library)
    }

    func cancel(_ job: DownloadJob) {
        running[job.id]?.cancel()
        handles[job.id]?.terminate()
        running[job.id] = nil
        handles[job.id] = nil
        pausedIDs.remove(job.id)
        if var current = jobs.first(where: { $0.id == job.id }) {
            current.state = .cancelled
            current.failureKind = .cancelled
            current.failureMessage = AppError.cancelled.localizedChinese
            current.updatedAt = Date()
            upsert(current)
        }
    }

    func pause(_ job: DownloadJob) {
        guard job.state.canPause else { return }
        handles[job.id]?.pause()
        pausedIDs.insert(job.id)
        if var current = jobs.first(where: { $0.id == job.id }) {
            current.state = .paused
            current.updatedAt = Date()
            upsert(current)
        }
    }

    func resume(_ job: DownloadJob, ytdlp: URL, ffmpeg: URL?, library: LibraryService) {
        if pausedIDs.contains(job.id), let handle = handles[job.id] {
            handle.resume()
            pausedIDs.remove(job.id)
            if var current = jobs.first(where: { $0.id == job.id }) {
                current.state = .downloading
                current.updatedAt = Date()
                upsert(current)
            }
            return
        }
        if var current = jobs.first(where: { $0.id == job.id }) {
            current.state = .queued
            current.updatedAt = Date()
            upsert(current)
        }
        pump(ytdlp: ytdlp, ffmpeg: ffmpeg, library: library)
    }

    func pump(ytdlp: URL, ffmpeg: URL?, library: LibraryService) {
        let limit = min(2, max(1, settings.concurrency))
        let active = jobs.filter { $0.state == .downloading || $0.state == .remuxing }.count
        let slots = max(0, limit - active)
        let waiting = jobs.filter { $0.state == .queued }
        for job in waiting.prefix(slots) {
            start(job, ytdlp: ytdlp, ffmpeg: ffmpeg, library: library)
        }
    }

    private func start(_ job: DownloadJob, ytdlp: URL, ffmpeg: URL?, library: LibraryService) {
        guard running[job.id] == nil else { return }
        var started = job
        started.state = .downloading
        started.updatedAt = Date()
        upsert(started)
        running[job.id] = Task { [weak self] in
            await self?.execute(started, ytdlp: ytdlp, ffmpeg: ffmpeg, library: library)
        }
    }

    private func execute(_ job: DownloadJob, ytdlp: URL, ffmpeg: URL?, library: LibraryService) async {
        let work = AppPaths.incompleteDirectory(root: settings.moviesRootURL).appendingPathComponent(job.id.uuidString, isDirectory: true)
        do {
            try AppPaths.ensureDirectory(work)
            try AppPaths.ensureStandardLayout(root: settings.moviesRootURL)
            let format = job.formatID ?? settings.defaultFormat.ytDlpFormat
            let template = settings.filenameTemplate.isEmpty
                ? "%(title)s [%(id)s].%(ext)s"
                : settings.filenameTemplate
            let preferAudio = FormatSelector.prefersAudioOnly(format)
            var progress = DownloadProgress(fraction: 0, speed: nil, eta: nil, destination: nil, phaseHint: nil)

            let downloaded = try await client.download(
                url: job.url,
                format: format,
                outputTemplate: template,
                workDirectory: work,
                cookies: settings.cookieFileURL,
                ytdlp: ytdlp,
                ffmpeg: ffmpeg,
                onStart: { [weak self] handle in
                    Task { @MainActor in
                        self?.handles[job.id] = handle
                    }
                },
                onProgressLine: { [weak self] line in
                    progress = ProgressParser.parse(line: line, current: progress)
                    Task { @MainActor in
                        self?.applyProgress(id: job.id, progress: progress)
                    }
                }
            )

            if Task.isCancelled { throw AppError.cancelled }

            if var current = jobs.first(where: { $0.id == job.id }) {
                current.state = .remuxing
                current.progress = max(current.progress, 0.97)
                current.updatedAt = Date()
                upsert(current)
            }

            let remuxed: URL
            if let ffmpeg {
                remuxed = try await remuxer.remuxIfNeeded(
                    input: downloaded,
                    ffmpeg: ffmpeg,
                    outputDirectory: work,
                    preferAudioOnly: preferAudio
                )
            } else {
                remuxed = downloaded
            }

            let duration = await library.readDuration(of: remuxed)
            guard var finished = jobs.first(where: { $0.id == job.id }) else { return }
            let item = try library.commitDownload(job: finished, file: remuxed, duration: duration, thumbnail: nil)
            finished.state = .completed
            finished.progress = 1
            finished.outputPath = item.filePath
            finished.updatedAt = Date()
            upsert(finished)
            try? FileManager.default.removeItem(at: work)
        } catch is CancellationError {
            markFailed(job.id, error: .cancelled)
        } catch let error as AppError {
            markFailed(job.id, error: error)
        } catch {
            markFailed(job.id, error: .downloadFailed(error.localizedDescription))
        }
        handles[job.id] = nil
        running[job.id] = nil
        pausedIDs.remove(job.id)
        pump(ytdlp: ytdlp, ffmpeg: ffmpeg, library: library)
    }

    private func applyProgress(id: UUID, progress: DownloadProgress) {
        guard var job = jobs.first(where: { $0.id == id }) else { return }
        guard job.state == .downloading || job.state == .paused else { return }
        job.progress = progress.fraction
        job.speed = progress.speed
        job.eta = progress.eta
        if progress.phaseHint == "合併中" {
            job.state = .remuxing
        }
        job.updatedAt = Date()
        upsert(job)
    }

    private func recoverInterrupted() {
        for job in jobs where job.state == .downloading || job.state == .remuxing || job.state == .probing {
            var recovered = job
            if job.state == .probing {
                recovered.state = .failed
                recovered.failureKind = .parseFailed
                recovered.failureMessage = "上次解析被中斷，請回到首頁再試。"
            } else {
                recovered.state = .queued
                recovered.failureMessage = nil
            }
            recovered.updatedAt = Date()
            upsert(recovered)
        }
    }

    private func upsert(_ job: DownloadJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
        }
        jobs.sort { $0.updatedAt > $1.updatedAt }
        do {
            try store.upsert(job)
        } catch {
            AppLog.error("job persist: \(error.localizedDescription)")
        }
    }
}

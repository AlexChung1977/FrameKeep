import AppKit
import AVFoundation
import Combine
import Darwin
import Foundation

@MainActor
final class LibraryService: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published var filter: LibraryFilter = .all
    @Published var formatFilter = ""

    private let db: SQLiteStore
    private let settings: AppSettings

    init(db: SQLiteStore, settings: AppSettings) {
        self.db = db
        self.settings = settings
        reload()
    }

    var itemsMatchingKind: [MediaItem] {
        switch filter {
        case .all: return items
        case .downloads: return items.filter { $0.kind == .download }
        case .captures: return items.filter { $0.kind == .capture }
        }
    }

    var availableFormats: [String] {
        Array(Set(itemsMatchingKind.map(\.fileFormat))).sorted()
    }

    var visibleItems: [MediaItem] {
        guard !formatFilter.isEmpty else { return itemsMatchingKind }
        return itemsMatchingKind.filter { $0.fileFormat == formatFilter }
    }

    func reload() {
        do {
            let rows = try db.query("SELECT * FROM media ORDER BY created_at DESC")
            items = rows.compactMap(Self.item(from:))
            for item in items {
                guard let source = item.sourceURL, item.exists else { continue }
                FileWhereFrom.stamp(file: item.fileURL, source: source)
            }
        } catch {
            AppLog.error("library reload: \(error.localizedDescription)")
            items = []
        }
    }

    func commitDownload(
        job: DownloadJob,
        file: URL,
        duration: TimeInterval?,
        thumbnail: URL?
    ) throws -> MediaItem {
        let stem = job.title.fileNameSafe(maxUTF8Bytes: 200)
        var dest = AppPaths.datedLibraryFile(
            root: settings.moviesRootURL,
            name: stem,
            ext: file.pathExtension
        )
        if FileManager.default.fileExists(atPath: dest.path) {
            let suffix = job.webpageID?.fileNameSafe(maxUTF8Bytes: 32) ?? String(job.id.uuidString.prefix(8))
            dest = AppPaths.datedLibraryFile(
                root: settings.moviesRootURL,
                name: "\(stem) [\(suffix)]",
                ext: file.pathExtension
            )
        }
        try AppPaths.ensureDirectory(dest.deletingLastPathComponent())
        let finalURL = try atomicMove(file, to: dest)
        FileWhereFrom.stamp(file: finalURL, source: job.url)
        let item = MediaItem(
            id: job.id,
            title: job.title,
            sourceURL: job.url,
            kind: .download,
            filePath: finalURL.path,
            thumbnailPath: thumbnail?.path,
            duration: duration,
            host: job.host,
            createdAt: Date()
        )
        try insert(item)
        reload()
        return item
    }

    func commitTrim(
        of source: MediaItem,
        file: URL,
        title: String,
        duration: TimeInterval,
        directory: URL? = nil
    ) throws -> MediaItem {
        let id = UUID()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = (trimmedTitle.isEmpty ? "\(source.title) 剪接" : trimmedTitle).fileNameSafe(maxUTF8Bytes: 180)
        let ext = file.pathExtension
        var dest: URL
        if let directory {
            dest = directory.appendingPathComponent("\(stem).\(ext)")
            if FileManager.default.fileExists(atPath: dest.path) {
                dest = directory.appendingPathComponent("\(stem) [\(id.uuidString.prefix(8))].\(ext)")
            }
        } else {
            dest = AppPaths.datedLibraryFile(root: settings.moviesRootURL, name: stem, ext: ext)
            if FileManager.default.fileExists(atPath: dest.path) {
                dest = AppPaths.datedLibraryFile(
                    root: settings.moviesRootURL,
                    name: "\(stem) [\(id.uuidString.prefix(8))]",
                    ext: ext
                )
            }
        }
        try AppPaths.ensureDirectory(dest.deletingLastPathComponent())
        let finalURL = try atomicMove(file, to: dest)
        if let page = source.sourceURL {
            FileWhereFrom.stamp(file: finalURL, source: page)
        }
        let item = MediaItem(
            id: id,
            title: trimmedTitle.isEmpty ? "\(source.title) 剪接" : trimmedTitle,
            sourceURL: source.sourceURL,
            kind: source.kind,
            filePath: finalURL.path,
            thumbnailPath: nil,
            duration: duration,
            host: source.host,
            createdAt: Date()
        )
        try insert(item)
        reload()
        return item
    }

    func commitCapture(
        title: String,
        file: URL,
        duration: TimeInterval?,
        sourceURL: URL?
    ) throws -> MediaItem {
        let id = UUID()
        try AppPaths.ensureDirectory(AppPaths.capturesDirectory(root: settings.moviesRootURL))
        let dest = AppPaths.capturesDirectory(root: settings.moviesRootURL)
            .appendingPathComponent("\(id.uuidString.prefix(8))_capture.\(file.pathExtension.isEmpty ? "mov" : file.pathExtension)")
        let finalURL = try atomicMove(file, to: dest)
        if let sourceURL {
            FileWhereFrom.stamp(file: finalURL, source: sourceURL)
        }
        let item = MediaItem(
            id: id,
            title: title,
            sourceURL: sourceURL,
            kind: .capture,
            filePath: finalURL.path,
            thumbnailPath: nil,
            duration: duration,
            host: "capture",
            createdAt: Date()
        )
        try insert(item)
        reload()
        return item
    }

    func reveal(_ item: MediaItem) {
        reveal([item])
    }

    func reveal(_ items: [MediaItem]) {
        let urls = items.map(\.fileURL)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func open(_ item: MediaItem) {
        open([item])
    }

    func open(_ items: [MediaItem]) {
        for item in items {
            NSWorkspace.shared.open(item.fileURL)
        }
    }

    func move(
        _ items: [MediaItem],
        to directory: URL,
        onProgress: @escaping @MainActor (LibraryMoveProgress) -> Void
    ) async -> String {
        let folder = directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "找不到目的資料夾。"
        }
        let total = items.count
        var moved = 0
        var failures: [String] = []
        for (offset, item) in items.enumerated() {
            let index = offset + 1
            let source = item.fileURL.standardizedFileURL
            func report(_ fileFraction: Double) {
                let overall = total == 0 ? 1 : (Double(offset) + min(1, max(0, fileFraction))) / Double(total)
                onProgress(LibraryMoveProgress(index: index, total: total, title: item.title, fraction: overall))
            }
            report(0)
            if source.deletingLastPathComponent().path == folder.path {
                do {
                    try removeFromLibrary(item.id)
                    moved += 1
                } catch {
                    failures.append("\(item.title)：\(error.localizedDescription)")
                }
                report(1)
                continue
            }
            guard FileManager.default.fileExists(atPath: source.path) else {
                failures.append("\(item.title)：找不到檔案")
                report(1)
                continue
            }
            let dest = uniqueFileURL(in: folder, fileName: source.lastPathComponent)
            let itemID = item.id
            do {
                try await Task.detached(priority: .userInitiated) {
                    try FileMover.transfer(from: source, to: dest) { fraction in
                        Task { @MainActor in report(fraction) }
                    }
                }.value
                try removeFromLibrary(itemID)
                moved += 1
                report(1)
            } catch {
                if FileManager.default.fileExists(atPath: dest.path), !FileManager.default.fileExists(atPath: source.path) {
                    try? await Task.detached(priority: .userInitiated) {
                        try FileMover.transfer(from: dest, to: source) { _ in }
                    }.value
                } else if FileManager.default.fileExists(atPath: dest.path), FileManager.default.fileExists(atPath: source.path) {
                    try? FileManager.default.removeItem(at: dest)
                }
                failures.append("\(item.title)：\(error.localizedDescription)")
                report(1)
            }
        }
        reload()
        let place = folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent
        if failures.isEmpty {
            return "已將 \(moved) 個檔案移到「\(place)」，並從媒體庫移除。"
        }
        if moved == 0 {
            return "沒有移動檔案。\(failures.prefix(2).joined(separator: " "))"
        }
        return "已移動 \(moved) 個到「\(place)」，並從媒體庫移除。\(failures.count) 個失敗：\(failures.prefix(2).joined(separator: " "))"
    }

    private func removeFromLibrary(_ id: UUID) throws {
        try db.run("DELETE FROM media WHERE id = ?") { [db] stmt in
            db.bindText(stmt, 1, id.uuidString)
        }
        VideoThumbnail.removeCache(for: id)
    }

    private func uniqueFileURL(in directory: URL, fileName: String) -> URL {
        let ext = (fileName as NSString).pathExtension
        let base = (fileName as NSString).deletingPathExtension
        var candidate = directory.appendingPathComponent(fileName)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            candidate = directory.appendingPathComponent(name)
            number += 1
        }
        return candidate
    }

    func rename(_ item: MediaItem, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try db.run("UPDATE media SET title = ? WHERE id = ?") { [db] stmt in
            db.bindText(stmt, 1, trimmed)
            db.bindText(stmt, 2, item.id.uuidString)
        }
        reload()
    }

    func delete(_ item: MediaItem, deleteFile: Bool) throws {
        try delete([item], deleteFile: deleteFile)
    }

    func delete(_ items: [MediaItem], deleteFile: Bool) throws {
        guard !items.isEmpty else { return }
        for item in items {
            if deleteFile, FileManager.default.fileExists(atPath: item.filePath) {
                try FileManager.default.removeItem(at: item.fileURL)
            }
            try db.run("DELETE FROM media WHERE id = ?") { [db] stmt in
                db.bindText(stmt, 1, item.id.uuidString)
            }
            VideoThumbnail.removeCache(for: item.id)
        }
        reload()
    }

    func readDuration(of url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        do {
            if #available(macOS 13.0, *) {
                let duration = try await asset.load(.duration)
                return duration.seconds.isFinite ? duration.seconds : nil
            } else {
                return asset.duration.seconds
            }
        } catch {
            return nil
        }
    }

    private func insert(_ item: MediaItem) throws {
        try db.run(
            """
            INSERT OR REPLACE INTO media (
                id, title, source_url, kind, file_path, thumbnail_path, duration, host, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        ) { [db] stmt in
            db.bindText(stmt, 1, item.id.uuidString)
            db.bindText(stmt, 2, item.title)
            db.bindText(stmt, 3, item.sourceURL?.absoluteString)
            db.bindText(stmt, 4, item.kind.rawValue)
            db.bindText(stmt, 5, item.filePath)
            db.bindText(stmt, 6, item.thumbnailPath)
            db.bindDouble(stmt, 7, item.duration)
            db.bindText(stmt, 8, item.host)
            db.bindDouble(stmt, 9, item.createdAt.timeIntervalSince1970)
        }
    }

    private func atomicMove(_ file: URL, to dest: URL) throws -> URL {
        try AppPaths.ensureDirectory(dest.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        do {
            try FileManager.default.moveItem(at: file, to: dest)
        } catch {
            try FileManager.default.copyItem(at: file, to: dest)
            try? FileManager.default.removeItem(at: file)
        }
        return dest
    }

    private static func item(from row: [String: SQLiteValue]) -> MediaItem? {
        guard let idText = row["id"]?.string, let id = UUID(uuidString: idText),
              let title = row["title"]?.string,
              let path = row["file_path"]?.string,
              let kindRaw = row["kind"]?.string, let kind = MediaKind(rawValue: kindRaw)
        else { return nil }
        return MediaItem(
            id: id,
            title: title,
            sourceURL: row["source_url"]?.string.flatMap(URL.init(string:)),
            kind: kind,
            filePath: path,
            thumbnailPath: row["thumbnail_path"]?.string,
            duration: row["duration"]?.double,
            host: row["host"]?.string,
            createdAt: Date(timeIntervalSince1970: row["created_at"]?.double ?? 0)
        )
    }
}

struct LibraryMoveProgress: Equatable {
    var index: Int
    var total: Int
    var title: String
    var fraction: Double
}

private enum FileMover {
    static func transfer(from source: URL, to dest: URL, onProgress: @escaping @Sendable (Double) -> Void) throws {
        if sameVolume(source, dest.deletingLastPathComponent()) {
            try FileManager.default.moveItem(at: source, to: dest)
            onProgress(1)
            return
        }
        try copyAcrossVolumes(from: source, to: dest, onProgress: onProgress)
        do {
            try FileManager.default.removeItem(at: source)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        onProgress(1)
    }

    private static func copyAcrossVolumes(from source: URL, to dest: URL, onProgress: @escaping @Sendable (Double) -> Void) throws {
        let total = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let output: FileHandle
        do {
            output = try FileHandle(forWritingTo: dest)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        defer { try? output.close() }

        let chunk = 8 * 1024 * 1024
        var copied: Int64 = 0
        var lastFraction = -1.0
        var lastReport = Date.distantPast
        do {
            while true {
                let data = try input.read(upToCount: chunk) ?? Data()
                if data.isEmpty { break }
                try output.write(contentsOf: data)
                copied += Int64(data.count)
                let fraction = total > 0 ? min(1, Double(copied) / Double(total)) : 1
                let now = Date()
                if fraction >= 1 || fraction - lastFraction >= 0.01 || now.timeIntervalSince(lastReport) >= 0.2 {
                    lastFraction = fraction
                    lastReport = now
                    onProgress(fraction)
                }
            }
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: source.path) {
            var kept: [FileAttributeKey: Any] = [:]
            if let permissions = attrs[.posixPermissions] { kept[.posixPermissions] = permissions }
            if let modified = attrs[.modificationDate] { kept[.modificationDate] = modified }
            try? FileManager.default.setAttributes(kept, ofItemAtPath: dest.path)
        }
        _ = copyfile(source.path, dest.path, nil, copyfile_flags_t(COPYFILE_METADATA))
    }

    private static func sameVolume(_ file: URL, _ directory: URL) -> Bool {
        var left = statfs()
        var right = statfs()
        guard statfs(file.path, &left) == 0, statfs(directory.path, &right) == 0 else { return false }
        return left.f_fsid.val.0 == right.f_fsid.val.0 && left.f_fsid.val.1 == right.f_fsid.val.1
    }
}

enum FileWhereFrom {
    private static let attribute = "com.apple.metadata:kMDItemWhereFroms"

    static func stamp(file: URL, source: URL) {
        let page = source.absoluteString
        guard !page.isEmpty, FileManager.default.fileExists(atPath: file.path) else { return }
        if current(file) == [page] { return }
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: [page],
            format: .binary,
            options: 0
        ) else { return }
        let wrote = data.withUnsafeBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return setxattr(file.path, attribute, base, buffer.count, 0, 0)
        }
        if wrote != 0 {
            AppLog.info("where-from skipped for \(file.lastPathComponent): \(String(cString: strerror(errno)))")
        }
    }

    private static func current(_ file: URL) -> [String]? {
        let size = getxattr(file.path, attribute, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { buffer -> ssize_t in
            guard let base = buffer.baseAddress else { return -1 }
            return getxattr(file.path, attribute, base, size, 0, 0)
        }
        guard read == size,
              let pages = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        else { return nil }
        return pages
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all
    case downloads
    case captures

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .downloads: return "下載"
        case .captures: return "擷取"
        }
    }
}

enum VideoThumbnail {
    static func jpeg(for item: MediaItem, ffmpegPath: String = "") async -> Data? {
        guard item.exists else { return nil }
        let cache = cacheURL(for: item)
        if let cached = try? Data(contentsOf: cache), !cached.isEmpty {
            return cached
        }
        guard let data = await makeJPEG(from: item.fileURL, ffmpegPath: ffmpegPath) else { return nil }
        try? AppPaths.ensureDirectory(AppPaths.thumbs)
        removeCache(for: item.id)
        try? data.write(to: cache, options: .atomic)
        return data
    }

    static func removeCache(for id: UUID) {
        let folder = AppPaths.thumbs
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(id.uuidString) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private static func cacheURL(for item: MediaItem) -> URL {
        let stamp = (try? item.fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        return AppPaths.thumbs.appendingPathComponent("\(item.id.uuidString)-\(Int(stamp)).jpg")
    }

    private static func makeJPEG(from url: URL, ffmpegPath: String) async -> Data? {
        if let data = await ffmpegJPEG(from: url, ffmpegPath: ffmpegPath) {
            return data
        }
        return await assetJPEG(from: url)
    }

    private static func ffmpegJPEG(from url: URL, ffmpegPath: String) async -> Data? {
        guard let ffmpeg = ffmpegExecutable(preferred: ffmpegPath) else { return nil }
        let directory = FileManager.default.temporaryDirectory
        for seek in ["1", "0"] {
            let dest = directory.appendingPathComponent("framekeep-\(UUID().uuidString).jpg")
            defer { try? FileManager.default.removeItem(at: dest) }
            let result = try? await ProcessRunner.run(
                executable: ffmpeg,
                arguments: [
                    "-y", "-ss", seek, "-i", url.path,
                    "-frames:v", "1",
                    "-vf", "scale=640:-2",
                    "-update", "1",
                    dest.path
                ],
                timeout: 40
            )
            guard result?.exitCode == 0,
                  let data = try? Data(contentsOf: dest),
                  !data.isEmpty
            else { continue }
            return data
        }
        return nil
    }

    static func ffmpegExecutable(preferred: String) -> URL? {
        var candidates = [preferred, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
        candidates = candidates.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func assetJPEG(from url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard !tracks.isEmpty else { return nil }
            let duration = try await asset.load(.duration)
            let seconds = duration.seconds
            let target = (seconds.isFinite && seconds > 0.4) ? min(1, seconds * 0.15) : 0
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 360)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.4, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.4, preferredTimescale: 600)
            let time = CMTime(seconds: max(0, target), preferredTimescale: 600)
            let cgImage: CGImage
            do {
                cgImage = try await generator.image(at: time).image
            } catch {
                cgImage = try await generator.image(at: .zero).image
            }
            return jpegData(from: cgImage)
        } catch {
            return nil
        }
    }

    private static func jpegData(from cgImage: CGImage) -> Data? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let normalized = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: normalized)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }
}

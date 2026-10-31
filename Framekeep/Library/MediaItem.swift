import Foundation
import UniformTypeIdentifiers

enum MediaKind: String, Codable, CaseIterable, Identifiable {
    case download
    case capture
    case imported

    var id: String { rawValue }

    var title: String {
        switch self {
        case .download: return "下載"
        case .capture: return "擷取"
        case .imported: return "匯入"
        }
    }
}

struct MediaItem: Identifiable, Hashable {
    var id: UUID
    var title: String
    var sourceURL: URL?
    var kind: MediaKind
    var filePath: String
    var thumbnailPath: String?
    var duration: TimeInterval?
    var host: String?
    var createdAt: Date

    var fileURL: URL { URL(fileURLWithPath: filePath) }

    var exists: Bool {
        FileManager.default.fileExists(atPath: filePath)
    }

    static func importedFile(_ url: URL) -> MediaItem {
        MediaItem(
            id: UUID(),
            title: url.deletingPathExtension().lastPathComponent,
            sourceURL: nil,
            kind: .imported,
            filePath: url.path,
            thumbnailPath: nil,
            duration: nil,
            host: nil,
            createdAt: Date()
        )
    }

    var durationLabel: String {
        guard let duration, duration > 0 else { return "" }
        let total = Int(duration.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

enum VideoFiles {
    private static let extensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "mpg", "mpeg", "ts", "m2ts", "wmv", "flv", "qt"
    ]

    static func isVideo(_ url: URL) -> Bool {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return false }
        let ext = url.pathExtension.lowercased()
        if extensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video) || type.conforms(to: .mpeg4Movie)
    }
}

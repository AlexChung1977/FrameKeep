import Foundation

enum MediaKind: String, Codable, CaseIterable, Identifiable {
    case download
    case capture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .download: return "下載"
        case .capture: return "擷取"
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

    var durationLabel: String {
        guard let duration, duration > 0 else { return "" }
        let total = Int(duration.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

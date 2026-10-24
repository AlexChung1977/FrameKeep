import Foundation

enum IngestSource: String, Codable, CaseIterable {
    case clipboard
    case dragDrop
    case manual
    case browser

    var title: String {
        switch self {
        case .clipboard: return "剪貼簿"
        case .dragDrop: return "拖放"
        case .manual: return "手動"
        case .browser: return "瀏覽器"
        }
    }
}

struct IngestRequest: Identifiable, Codable, Hashable {
    let id: UUID
    let url: URL
    let source: IngestSource
    let timestamp: Date
    let originalText: String

    init(id: UUID = UUID(), url: URL, source: IngestSource, timestamp: Date = Date(), originalText: String) {
        self.id = id
        self.url = url
        self.source = source
        self.timestamp = timestamp
        self.originalText = originalText
    }
}

import SwiftUI

enum SidebarDestination: String, CaseIterable, Identifiable, Hashable {
    case home
    case queue
    case library
    case capture
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "首頁"
        case .queue: return "佇列"
        case .library: return "媒體庫"
        case .capture: return "擷取"
        case .settings: return "設定"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .queue: return "list.bullet.rectangle"
        case .library: return "square.grid.2x2"
        case .capture: return "record.circle"
        case .settings: return "gearshape"
        }
    }
}

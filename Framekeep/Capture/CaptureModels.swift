import CoreGraphics
import Foundation

struct CaptureDisplay: Identifiable, Hashable {
    var id: CGDirectDisplayID
    var name: String
    var width: Int
    var height: Int
    var isMain: Bool

    var label: String {
        let mark = isMain ? "（主螢幕）" : ""
        return "\(name) · \(width)×\(height)\(mark)"
    }
}

enum CapturePhase: Equatable {
    case idle
    case requestingPermission
    case ready
    case recording
    case paused
    case saving
    case failed(String)

    var title: String {
        switch self {
        case .idle: return "未就緒"
        case .requestingPermission: return "等候權限"
        case .ready: return "就緒"
        case .recording: return "錄製中"
        case .paused: return "已暫停"
        case .saving: return "寫入檔案"
        case .failed: return "失敗"
        }
    }
}

struct CapturePermissionState: Equatable {
    var screenGranted: Bool
    var microphoneGranted: Bool

    static let unknown = CapturePermissionState(screenGranted: false, microphoneGranted: false)
}

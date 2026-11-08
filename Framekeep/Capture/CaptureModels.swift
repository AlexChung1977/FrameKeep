import CoreGraphics
import Foundation

struct CaptureDisplay: Identifiable, Hashable {
    var id: CGDirectDisplayID
    var name: String
    var width: Int
    var height: Int
    var refreshRateHz: Int
    var isMain: Bool

    var refreshLabel: String {
        "\(max(refreshRateHz, 1))Hz"
    }

    var label: String {
        let mark = isMain ? "（主螢幕）" : ""
        return "\(name) · \(width)×\(height) · \(refreshLabel)\(mark)"
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

/// Capture encode FPS. `auto` follows the display (capped at 60, or 120 with HDR).
enum CaptureFPSChoice: Int, CaseIterable, Identifiable, Codable {
    case auto = 0
    case fps24 = 24
    case fps30 = 30
    case fps48 = 48
    case fps60 = 60
    case fps120 = 120

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .auto: return "自動"
        case .fps24: return "24 fps"
        case .fps30: return "30 fps"
        case .fps48: return "48 fps"
        case .fps60: return "60 fps"
        case .fps120: return "120 fps"
        }
    }

    /// Choices that fit the selected display and HDR mode.
    static func available(displayHz: Int, hdr: Bool) -> [CaptureFPSChoice] {
        let cap = min(max(displayHz, 30), hdr ? 120 : 60)
        return allCases.filter { choice in
            if choice == .auto { return true }
            return choice.rawValue <= cap
        }
    }

    func resolvedFPS(displayHz: Int, hdr: Bool) -> Int {
        let cap = min(max(displayHz, 30), hdr ? 120 : 60)
        switch self {
        case .auto:
            return cap
        default:
            return min(max(rawValue, 24), cap)
        }
    }
}

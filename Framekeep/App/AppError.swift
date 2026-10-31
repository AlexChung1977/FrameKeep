import Foundation

enum AppError: LocalizedError, Equatable {
    case emptyURL
    case invalidURL(String)
    case toolMissing(String)
    case probeFailed(String)
    case downloadFailed(String)
    case remuxFailed(String)
    case captureFailed(String)
    case permissionDenied(String)
    case diskSpace
    case cancelled
    case unsupported
    case needsLogin
    case botCheck
    case suspectedDRM
    case policyBlocked(String)
    case store(String)

    var errorDescription: String? {
        localizedChinese
    }

    var localizedChinese: String {
        switch self {
        case .emptyURL:
            return "請先貼上連結。"
        case .invalidURL(let raw):
            return "無法辨識這個連結：\(raw)"
        case .toolMissing(let name):
            return "找不到 \(name)。請先用 Homebrew 安裝，或在設定中指定路徑。"
        case .probeFailed(let reason):
            return "解析失敗：\(reason)"
        case .downloadFailed(let reason):
            return "下載失敗：\(reason)"
        case .remuxFailed(let reason):
            return "合併影音失敗：\(reason)"
        case .captureFailed(let reason):
            return "擷取失敗：\(reason)"
        case .permissionDenied(let name):
            return "尚未授權\(name)。請到系統設定開啟權限。"
        case .diskSpace:
            return "磁碟空間不足，無法繼續寫入檔案。"
        case .cancelled:
            return "已取消。"
        case .unsupported:
            return "這個網址目前無法解析下載。可以改用擷取模式。"
        case .needsLogin:
            return "此內容需要登入。可匯入你自己的 cookies.txt，或改用擷取。"
        case .botCheck:
            return "YouTube 正在拒絕這台電腦的匿名下載，不是這支影片需要登入。換片或重試不會過。可在設定匯入你自己的 cookies.txt，或改用擷取。"
        case .suspectedDRM:
            return "此內容疑似受 DRM 保護。Framekeep 不會解密或規避；請改用合法播放＋擷取。"
        case .policyBlocked(let reason):
            return "平台政策或權限阻擋：\(reason)"
        case .store(let reason):
            return "儲存資料失敗：\(reason)"
        }
    }

    var suggestsCapture: Bool {
        switch self {
        case .unsupported, .suspectedDRM, .policyBlocked, .needsLogin, .botCheck, .probeFailed, .downloadFailed:
            return true
        default:
            return false
        }
    }
}

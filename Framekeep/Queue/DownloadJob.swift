import Foundation

enum JobState: String, Codable, CaseIterable {
    case queued
    case probing
    case awaitingFormat
    case downloading
    case remuxing
    case paused
    case completed
    case failed
    case cancelled

    var title: String {
        switch self {
        case .queued: return "排隊中"
        case .probing: return "解析中"
        case .awaitingFormat: return "待選格式"
        case .downloading: return "下載中"
        case .remuxing: return "合併中"
        case .paused: return "已暫停"
        case .completed: return "已完成"
        case .failed: return "失敗"
        case .cancelled: return "已取消"
        }
    }

    var isActive: Bool {
        switch self {
        case .queued, .probing, .downloading, .remuxing, .paused: return true
        default: return false
        }
    }

    var canPause: Bool { self == .downloading }
    var canResume: Bool { self == .paused || self == .queued }
    var canRetry: Bool { self == .failed || self == .cancelled }
    var canCancel: Bool {
        switch self {
        case .completed, .cancelled: return false
        default: return true
        }
    }
}

enum FailureKind: String, Codable {
    case network
    case parseFailed
    case needsLogin
    case botCheck
    case policyBlocked
    case diskSpace
    case toolMissing
    case cancelled
    case unknown

    var title: String {
        switch self {
        case .network: return "網路"
        case .parseFailed: return "解析失效"
        case .needsLogin: return "需登入"
        case .botCheck: return "被拒絕"
        case .policyBlocked: return "政策阻擋"
        case .diskSpace: return "磁碟空間"
        case .toolMissing: return "工具缺失"
        case .cancelled: return "已取消"
        case .unknown: return "其他"
        }
    }

    static func from(_ error: AppError) -> FailureKind {
        switch error {
        case .needsLogin: return .needsLogin
        case .botCheck: return .botCheck
        case .policyBlocked: return .policyBlocked
        case .diskSpace: return .diskSpace
        case .toolMissing: return .toolMissing
        case .cancelled: return .cancelled
        case .probeFailed, .unsupported: return .parseFailed
        case .downloadFailed: return .network
        default: return .unknown
        }
    }
}

struct DownloadJob: Identifiable, Hashable {
    var id: UUID
    var url: URL
    var title: String
    var state: JobState
    var formatID: String?
    var formatLabel: String?
    var progress: Double
    var speed: String?
    var eta: String?
    var failureKind: FailureKind?
    var failureMessage: String?
    var outputPath: String?
    var source: IngestSource
    var createdAt: Date
    var updatedAt: Date
    var webpageID: String?
    var host: String

    var progressPercent: Int {
        Int((min(1, max(0, progress)) * 100).rounded())
    }

    var humanFailure: String {
        failureMessage ?? failureKind?.title ?? "發生錯誤"
    }
}

extension DownloadJob {
    static func probing(request: IngestRequest) -> DownloadJob {
        DownloadJob(
            id: request.id,
            url: request.url,
            title: request.url.host ?? request.url.absoluteString,
            state: .probing,
            formatID: nil,
            formatLabel: nil,
            progress: 0,
            speed: nil,
            eta: nil,
            failureKind: nil,
            failureMessage: nil,
            outputPath: nil,
            source: request.source,
            createdAt: request.timestamp,
            updatedAt: Date(),
            webpageID: nil,
            host: request.url.host ?? ""
        )
    }
}

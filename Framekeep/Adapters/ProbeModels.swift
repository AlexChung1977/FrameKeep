import Foundation

enum Capability: String, Codable, Equatable {
    case downloadable
    case needsLogin
    case suspectedDRM
    case captureOnly
    case unsupported

    var title: String {
        switch self {
        case .downloadable: return "可下載"
        case .needsLogin: return "需要登入"
        case .suspectedDRM: return "疑似 DRM"
        case .captureOnly: return "僅能擷取"
        case .unsupported: return "不支援下載"
        }
    }

    var suggestsCapture: Bool {
        self != .downloadable
    }
}

struct MediaFormat: Identifiable, Hashable, Codable {
    let id: String
    let label: String
    let height: Int?
    let width: Int?
    let ext: String
    let vcodec: String?
    let acodec: String?
    let filesize: Int64?
    let fps: Double?
    let abr: Double?
    let note: String?
    let isAudioOnly: Bool
    let isVideoOnly: Bool

    var hasVideo: Bool {
        let codec = vcodec?.lowercased() ?? "none"
        return !isAudioOnly && codec != "none" && codec != "images"
    }

    var selectionLabel: String {
        isVideoOnly ? "\(label)（會合併音訊）" : label
    }

    var resolutionLabel: String {
        if let height { return "\(height)p" }
        if isAudioOnly { return "音訊" }
        return ext.uppercased()
    }

    var codecLabel: String {
        let v = Self.shortCodec(vcodec)
        let a = Self.shortCodec(acodec)
        if isAudioOnly { return a }
        if isVideoOnly { return v }
        if v != "—" && a != "—" { return "\(v) + \(a)" }
        return v != "—" ? v : a
    }

    var sizeLabel: String? {
        guard let filesize, filesize > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: filesize, countStyle: .file)
    }

    private static func shortCodec(_ raw: String?) -> String {
        guard let raw, raw != "none", !raw.isEmpty else { return "—" }
        let head = raw.split(separator: ".").first.map(String.init) ?? raw
        return head
    }
}

struct ProbeResult: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let title: String
    let thumbnailURL: URL?
    let duration: TimeInterval?
    let sourceHost: String
    let extractor: String
    let formats: [MediaFormat]
    let requiresCookie: Bool
    let capability: Capability
    let message: String?
    let webpageID: String?

    init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        thumbnailURL: URL?,
        duration: TimeInterval?,
        sourceHost: String,
        extractor: String,
        formats: [MediaFormat],
        requiresCookie: Bool,
        capability: Capability,
        message: String?,
        webpageID: String?
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.duration = duration
        self.sourceHost = sourceHost
        self.extractor = extractor
        self.formats = formats
        self.requiresCookie = requiresCookie
        self.capability = capability
        self.message = message
        self.webpageID = webpageID
    }

    var durationLabel: String {
        guard let duration, duration > 0 else { return "時長未知" }
        let total = Int(duration.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    func recommendedFormat(for preset: DefaultFormatPreset) -> MediaFormat? {
        switch preset {
        case .audioOnly:
            return formats.first(where: { $0.isAudioOnly }) ?? formats.last
        case .balanced:
            let withVideo = formats.filter(\.hasVideo)
            return withVideo.first(where: { ($0.height ?? 0) <= 720 && ($0.height ?? 0) >= 480 })
                ?? withVideo.first(where: { ($0.height ?? 0) <= 720 })
                ?? withVideo.first
        case .best, .custom:
            return formats.first(where: \.hasVideo) ?? formats.first
        }
    }
}

enum FormatSelector {
    static func ytDlpSelector(preset: DefaultFormatPreset, custom: MediaFormat?) -> String {
        if preset == .custom, let custom {
            if custom.isAudioOnly {
                return "\(custom.id)/bestaudio"
            }
            if custom.isVideoOnly {
                return "\(custom.id)+bestaudio/bestaudio+\(custom.id)/\(custom.id)"
            }
            return custom.id
        }
        return preset.ytDlpFormat
    }

    /// Merge selectors such as `137+bestaudio` still contain the word bestaudio,
    /// but they must keep the video track. Only a pure audio selector extracts audio.
    static func prefersAudioOnly(_ format: String) -> Bool {
        if format.contains("+") || format.contains("bestvideo") {
            return false
        }
        return format.contains("bestaudio")
    }

    static func label(preset: DefaultFormatPreset, custom: MediaFormat?) -> String {
        if preset == .custom, let custom { return custom.label }
        return preset.title
    }
}

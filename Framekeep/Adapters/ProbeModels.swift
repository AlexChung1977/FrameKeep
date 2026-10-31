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
        let v = Self.prettyCodec(vcodec)
        let a = Self.prettyCodec(acodec)
        if isAudioOnly { return a }
        if isVideoOnly { return v }
        if v != "—" && a != "—" { return "\(v) + \(a)" }
        return v != "—" ? v : a
    }

    /// Width, height, and the video codec name shown in the queue.
    var technicalLabel: String {
        if isAudioOnly {
            let audio = Self.prettyCodec(acodec)
            return audio == "—" ? "音訊" : "音訊 · \(audio)"
        }
        var parts: [String] = []
        if let width, width > 0, let height, height > 0 {
            parts.append("\(width)×\(height)")
        } else if let height, height > 0 {
            parts.append("\(height)p")
        }
        if let fps = Self.fpsText(fps) { parts.append(fps) }
        let video = Self.prettyCodec(vcodec)
        if video != "—" { parts.append(video) }
        return parts.joined(separator: " · ")
    }

    var fpsLabel: String? {
        Self.fpsText(fps)
    }

    static func fpsText(_ fps: Double?) -> String? {
        guard let fps, fps > 1, fps < 1000 else { return nil }
        let known: [(Double, String)] = [
            (23.976, "23.976"), (24, "24"), (25, "25"),
            (29.97, "29.97"), (30, "30"), (48, "48"),
            (50, "50"), (59.94, "59.94"), (60, "60"), (120, "120")
        ]
        if let match = known.first(where: { abs(fps - $0.0) < 0.02 }) {
            return "\(match.1) FPS"
        }
        if abs(fps - fps.rounded()) < 0.05 {
            return "\(Int(fps.rounded())) FPS"
        }
        return String(format: "%.2f FPS", fps)
    }

    /// Lower is better. Same resolution should prefer AV1, then other efficient codecs.
    static func codecQualityRank(_ raw: String?) -> Int {
        let codec = (raw ?? "").lowercased()
        if codec.hasPrefix("av01") || codec.hasPrefix("av1") { return 0 }
        if codec.hasPrefix("vp09.02") || codec.hasPrefix("vp9.2") { return 1 }
        if codec.hasPrefix("vp09") || codec.hasPrefix("vp9") { return 2 }
        if codec.hasPrefix("hev1") || codec.hasPrefix("hvc1") || codec.hasPrefix("hevc") || codec.hasPrefix("h265") { return 3 }
        if codec.hasPrefix("avc1") || codec.hasPrefix("h264") { return 4 }
        if codec.isEmpty || codec == "none" { return 20 }
        return 10
    }

    static func prettyCodec(_ raw: String?) -> String {
        guard let raw, raw != "none", !raw.isEmpty else { return "—" }
        let head = raw.split(separator: ".").first.map { String($0).lowercased() } ?? raw.lowercased()
        switch head {
        case "av01", "av1": return "AV1"
        case "vp09", "vp9": return "VP9"
        case "vp8", "vp08": return "VP8"
        case "avc1", "avc", "h264": return "H.264"
        case "hev1", "hvc1", "hevc", "h265": return "HEVC"
        case "mp4a", "aac": return "AAC"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        case "mp3": return "MP3"
        default: return head.uppercased()
        }
    }

    var sizeLabel: String? {
        guard let filesize, filesize > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: filesize, countStyle: .file)
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
        case .custom:
            return formats.first(where: \.hasVideo) ?? formats.first
        case .best:
            return formats.filter(\.hasVideo).sorted(by: FormatSelector.prefersHigherQuality).first
                ?? formats.first
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
        let detail = custom?.technicalLabel ?? ""
        if preset == .custom {
            return detail.isEmpty ? (custom?.label ?? preset.title) : detail
        }
        if detail.isEmpty { return preset.title }
        return "\(preset.title) · \(detail)"
    }

    /// Highest resolution first. At the same resolution, AV1 comes before VP9, HEVC, then H.264.
    static func prefersHigherQuality(_ lhs: MediaFormat, _ rhs: MediaFormat) -> Bool {
        let leftHeight = lhs.height ?? 0
        let rightHeight = rhs.height ?? 0
        if leftHeight != rightHeight { return leftHeight > rightHeight }
        let leftCodec = MediaFormat.codecQualityRank(lhs.vcodec)
        let rightCodec = MediaFormat.codecQualityRank(rhs.vcodec)
        if leftCodec != rightCodec { return leftCodec < rightCodec }
        if (lhs.fps ?? 0) != (rhs.fps ?? 0) { return (lhs.fps ?? 0) > (rhs.fps ?? 0) }
        return (lhs.filesize ?? 0) > (rhs.filesize ?? 0)
    }

    static func ytDlpSort(for format: String) -> String? {
        guard format == DefaultFormatPreset.best.ytDlpFormat else { return nil }
        return "res,fps,vcodec:av01:vp9.2:vp9:hev1:hvc1:avc1,acodec:opus:mp4a"
    }
}

enum MediaFileInfo {
    static func label(for file: URL, ffmpeg: URL) async -> String? {
        let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        if FileManager.default.isExecutableFile(atPath: ffprobe.path),
           let label = await probe(ffprobe, file: file) {
            return label
        }
        return await probeWithFFmpeg(ffmpeg, file: file)
    }

    private static func probe(_ ffprobe: URL, file: URL) async -> String? {
        let result = try? await ProcessRunner.run(
            executable: ffprobe,
            arguments: [
                "-v", "error",
                "-show_entries", "stream=codec_type,codec_name,width,height,avg_frame_rate",
                "-of", "json",
                file.path
            ],
            timeout: 30
        )
        guard let data = result?.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = object["streams"] as? [[String: Any]]
        else { return nil }
        return label(from: streams)
    }

    private static func probeWithFFmpeg(_ ffmpeg: URL, file: URL) async -> String? {
        let result: ProcessResult?
        do {
            result = try await ProcessRunner.run(
                executable: ffmpeg,
                arguments: ["-hide_banner", "-i", file.path],
                timeout: 30
            )
        } catch let error as ProcessRunnerError {
            if case .nonZeroExit(_, let stderr) = error {
                return label(fromFFmpegLog: stderr)
            }
            return nil
        } catch {
            return nil
        }
        return label(fromFFmpegLog: (result?.stderr ?? "") + "\n" + (result?.stdout ?? ""))
    }

    private static func label(from streams: [[String: Any]]) -> String? {
        let video = streams.first { ($0["codec_type"] as? String) == "video" }
        if let video {
            let width = video["width"] as? Int ?? Int(video["width"] as? Double ?? 0)
            let height = video["height"] as? Int ?? Int(video["height"] as? Double ?? 0)
            let codec = MediaFormat.prettyCodec(video["codec_name"] as? String)
            let fps = MediaFormat.fpsText(Self.frameRate(video["avg_frame_rate"]))
            var parts: [String] = []
            if width > 0, height > 0 {
                parts.append("\(width)×\(height)")
            }
            if let fps { parts.append(fps) }
            if codec != "—" { parts.append(codec) }
            if !parts.isEmpty { return parts.joined(separator: " · ") }
        }
        if let audio = streams.first(where: { ($0["codec_type"] as? String) == "audio" }) {
            let codec = MediaFormat.prettyCodec(audio["codec_name"] as? String)
            return codec == "—" ? "音訊" : "音訊 · \(codec)"
        }
        return nil
    }

    private static func label(fromFFmpegLog log: String) -> String? {
        for line in log.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard let video = text.range(of: "Video:") else { continue }
            let rest = text[video.upperBound...]
            let codec = rest.split(separator: " ").first.map { MediaFormat.prettyCodec(String($0)) } ?? "—"
            var parts: [String] = []
            if let match = rest.range(of: #"\d{2,5}x\d{2,5}"#, options: .regularExpression) {
                parts.append(rest[match].replacingOccurrences(of: "x", with: "×"))
            }
            if let match = rest.range(of: #"\d+(?:\.\d+)?\s+fps"#, options: .regularExpression) {
                let number = rest[match].replacingOccurrences(of: "fps", with: "").trimmingCharacters(in: .whitespaces)
                if let fps = MediaFormat.fpsText(Double(number)) { parts.append(fps) }
            }
            if codec != "—" { parts.append(codec) }
            if !parts.isEmpty { return parts.joined(separator: " · ") }
        }
        return nil
    }

    private static func frameRate(_ value: Any?) -> Double? {
        guard let text = value as? String else { return nil }
        let pieces = text.split(separator: "/")
        if pieces.count == 2,
           let numerator = Double(pieces[0]),
           let denominator = Double(pieces[1]),
           denominator > 0 {
            let fps = numerator / denominator
            return fps > 1 ? fps : nil
        }
        guard let fps = Double(text), fps > 1 else { return nil }
        return fps
    }
}

import Foundation

/// Direct media / HLS URLs. No site-specific reverse engineering.
struct GenericStreamAdapter: ExtractorAdapter {
    let name = "Generic stream"
    let client: YtDlpClient

    private let extensions: Set<String> = ["mp4", "m4v", "webm", "mkv", "mov", "m3u8", "mpd", "m4a", "aac", "mp3", "opus", "wav"]

    func canHandle(url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    func probe(url: URL, cookies: URL?, ytdlp: URL, ffmpeg: URL?) async throws -> ProbeResult {
        do {
            return try await client.probe(url: url, cookies: cookies, ytdlp: ytdlp, ffmpeg: ffmpeg)
        } catch {
            let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension.lowercased()
            let isAudio = ["m4a", "aac", "mp3", "opus", "wav"].contains(ext)
            let format = MediaFormat(
                id: "source",
                label: isAudio ? "原始音訊 · \(ext.uppercased())" : "原始串流 · \(ext.uppercased())",
                height: nil,
                width: nil,
                ext: ext,
                vcodec: isAudio ? "none" : "unknown",
                acodec: "unknown",
                filesize: nil,
                fps: nil,
                abr: nil,
                note: "直接位址",
                isAudioOnly: isAudio,
                isVideoOnly: false
            )
            return ProbeResult(
                url: url,
                title: url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.lastPathComponent,
                thumbnailURL: nil,
                duration: nil,
                sourceHost: url.host ?? "direct",
                extractor: "generic-stream",
                formats: [format],
                requiresCookie: false,
                capability: .downloadable,
                message: "以公開串流位址直接下載。",
                webpageID: nil
            )
        }
    }
}

import Foundation

protocol ExtractorAdapter {
    var name: String { get }
    func canHandle(url: URL) -> Bool
    func probe(url: URL, cookies: URL?, ytdlp: URL, ffmpeg: URL?) async throws -> ProbeResult
}

struct ExtractorRegistry {
    let adapters: [ExtractorAdapter]

    init(ytdlpClient: YtDlpClient) {
        adapters = [
            YouTubeAdapter(client: ytdlpClient),
            GenericStreamAdapter(client: ytdlpClient),
            YtDlpGenericAdapter(client: ytdlpClient)
        ]
    }

    func adapter(for url: URL) -> ExtractorAdapter {
        adapters.first(where: { $0.canHandle(url: url) }) ?? adapters.last!
    }
}

import AppKit
import Foundation

enum URLIngestService {
    static func makeRequest(from raw: String, source: IngestSource) throws -> IngestRequest {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppError.emptyURL }
        guard let url = normalize(trimmed) else { throw AppError.invalidURL(trimmed) }
        return IngestRequest(url: url, source: source, originalText: trimmed)
    }

    static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<") && text.hasSuffix(">") {
            text = String(text.dropFirst().dropLast())
        }
        if text.contains("http"), let match = firstURL(in: text) {
            text = match
        }
        if !text.contains("://") {
            text = "https://\(text)"
        }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty else {
            return nil
        }
        components.fragment = nil
        if let items = components.queryItems, !items.isEmpty {
            components.queryItems = items.filter { item in
                let name = item.name.lowercased()
                return !(name.hasPrefix("utm_") || name == "fbclid" || name == "gclid" || name == "si")
            }
            if components.queryItems?.isEmpty == true {
                components.queryItems = nil
            }
        }
        if let expanded = expandShortYouTube(components) {
            return expanded
        }
        return components.url
    }

    static func pasteboardURLString() -> String? {
        let pb = NSPasteboard.general
        if let url = pb.string(forType: .URL), !url.isEmpty { return url }
        if let text = pb.string(forType: .string) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalize(trimmed) != nil { return trimmed }
        }
        return nil
    }

    /// Best-effort redirect follow for a few public short-hosts. Failures are ignored.
    static func expandIfShort(_ url: URL) async -> URL {
        let shortHosts = ["youtu.be", "t.co", "bit.ly", "tinyurl.com"]
        guard let host = url.host?.lowercased(), shortHosts.contains(host) else { return url }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        request.setValue("Framekeep/0.1", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, let final = http.url {
                return normalize(final.absoluteString) ?? final
            }
        } catch {
            AppLog.info("short-url expand skipped: \(error.localizedDescription)")
        }
        return url
    }

    private static func firstURL(in text: String) -> String? {
        let pattern = #"https?://[^\s<>\"]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    private static func expandShortYouTube(_ components: URLComponents) -> URL? {
        guard components.host?.lowercased() == "youtu.be" else { return nil }
        let videoID = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !videoID.isEmpty else { return components.url }
        var dest = URLComponents()
        dest.scheme = "https"
        dest.host = "www.youtube.com"
        dest.path = "/watch"
        var items = [URLQueryItem(name: "v", value: videoID)]
        if let extra = components.queryItems { items.append(contentsOf: extra) }
        dest.queryItems = items
        return dest.url
    }
}

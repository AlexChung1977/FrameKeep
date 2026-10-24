import Foundation

struct DownloadProgress: Equatable {
    var fraction: Double
    var speed: String?
    var eta: String?
    var destination: String?
    var phaseHint: String?
}

enum ProgressParser {
    static func parse(line: String, current: DownloadProgress) -> DownloadProgress {
        var next = current
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[download]") {
            if let percent = firstMatch(trimmed, pattern: #"([0-9]+(?:\.[0-9]+)?)%"#) {
                next.fraction = min(1, (Double(percent) ?? 0) / 100)
            }
            if let speed = firstMatch(trimmed, pattern: #"at\s+(\S+/s)"#) {
                next.speed = speed
            }
            if let eta = firstMatch(trimmed, pattern: #"ETA\s+(\S+)"#) {
                next.eta = eta
            }
            if trimmed.contains("Destination:") {
                next.destination = trimmed.components(separatedBy: "Destination:").last?
                    .trimmingCharacters(in: .whitespaces)
            }
            next.phaseHint = "下載中"
        } else if trimmed.contains("[Merger]") || trimmed.contains("[ExtractAudio]") || trimmed.contains("[Fixup") {
            next.phaseHint = "合併中"
            next.fraction = max(next.fraction, 0.96)
        } else if trimmed.contains("Deleting original") {
            next.phaseHint = "清理暫存"
        }
        return next
    }

    static func destinationPath(in transcript: String) -> String? {
        let lines = transcript.split(whereSeparator: \.isNewline).map(String.init)
        for line in lines.reversed() {
            if line.contains("Destination:"),
               let path = line.components(separatedBy: "Destination:").last?.trimmingCharacters(in: .whitespaces),
               !path.isEmpty {
                return path
            }
            if line.contains("Merging formats into"),
               let quoted = firstMatch(line, pattern: #"\"([^\"]+)\""#) {
                return quoted
            }
        }
        return nil
    }

    private static func firstMatch(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let swift = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[swift])
    }
}

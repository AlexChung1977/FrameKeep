import Foundation

enum AppLog {
    private static let queue = DispatchQueue(label: "app.framekeep.log")
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func info(_ message: String) {
        write(level: "INFO", message: message)
    }

    static func error(_ message: String) {
        write(level: "ERROR", message: message)
    }

    static func redactCookies(_ arguments: [String]) -> String {
        var redacted: [String] = []
        var hideNext = false
        for arg in arguments {
            if hideNext {
                redacted.append("<cookie-file>")
                hideNext = false
                continue
            }
            if arg == "--cookies" || arg == "--cookies-from-browser" {
                redacted.append(arg)
                hideNext = true
                continue
            }
            redacted.append(arg)
        }
        return redacted.joined(separator: " ")
    }

    private static func write(level: String, message: String) {
        let line = "\(iso.string(from: Date())) [\(level)] \(message)\n"
        queue.async {
            do {
                try AppPaths.ensureDirectory(AppPaths.logs)
                let file = AppPaths.logs.appendingPathComponent("framekeep.log")
                if !FileManager.default.fileExists(atPath: file.path) {
                    FileManager.default.createFile(atPath: file.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
                rotateIfNeeded(file)
            } catch {
                NSLog("Framekeep log write failed: %@", error.localizedDescription)
            }
        }
    }

    private static func rotateIfNeeded(_ file: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? NSNumber,
              size.int64Value > 1_500_000
        else { return }
        let backup = AppPaths.logs.appendingPathComponent("framekeep.prev.log")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: file, to: backup)
    }
}

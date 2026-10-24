import Foundation

enum AppPaths {
    static let defaultMoviesFolderName = "Framekeep"

    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Framekeep", isDirectory: true)
    }

    static var caches: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("Framekeep", isDirectory: true)
    }

    static var logs: URL {
        applicationSupport.appendingPathComponent("logs", isDirectory: true)
    }

    static var databaseFile: URL {
        applicationSupport.appendingPathComponent("db.sqlite")
    }

    static var thumbs: URL {
        caches.appendingPathComponent("thumbs", isDirectory: true)
    }

    static var probeCache: URL {
        caches.appendingPathComponent("probe", isDirectory: true)
    }

    static func defaultMoviesRoot() -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        return movies.appendingPathComponent(defaultMoviesFolderName, isDirectory: true)
    }

    static func libraryDirectory(root: URL) -> URL {
        root.appendingPathComponent("Library", isDirectory: true)
    }

    static func capturesDirectory(root: URL) -> URL {
        root.appendingPathComponent("Captures", isDirectory: true)
    }

    static func incompleteDirectory(root: URL) -> URL {
        root.appendingPathComponent("Incomplete", isDirectory: true)
    }

    static func exportsDirectory(root: URL) -> URL {
        root.appendingPathComponent("Exports", isDirectory: true)
    }

    @discardableResult
    static func ensureDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func ensureStandardLayout(root: URL) throws {
        try ensureDirectory(applicationSupport)
        try ensureDirectory(logs)
        try ensureDirectory(caches)
        try ensureDirectory(thumbs)
        try ensureDirectory(probeCache)
        try ensureDirectory(root)
        try ensureDirectory(libraryDirectory(root: root))
        try ensureDirectory(capturesDirectory(root: root))
        try ensureDirectory(incompleteDirectory(root: root))
        try ensureDirectory(exportsDirectory(root: root))
    }

    static func datedLibraryDirectory(root: URL, date: Date = Date()) -> URL {
        let cal = Calendar.current
        let year = String(cal.component(.year, from: date))
        let month = String(format: "%02d", cal.component(.month, from: date))
        return libraryDirectory(root: root)
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
    }

    static func datedLibraryFile(root: URL, name: String, ext: String, date: Date = Date()) -> URL {
        let folder = datedLibraryDirectory(root: root, date: date)
        let safeExt = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
        return folder.appendingPathComponent("\(name.fileNameSafe()).\(safeExt)")
    }
}

extension String {
    /// Keeps the original title, including spaces and non-ASCII. Only characters
    /// that cannot appear in a macOS file name are replaced.
    func fileNameSafe(maxUTF8Bytes: Int = 240) -> String {
        var output = ""
        for scalar in trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { continue }
            switch scalar {
            case "/", ":", "\\":
                output.append("-")
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output = clipUTF8(output, maxBytes: maxUTF8Bytes)
        while output.last == "." || output.last == " " {
            output.removeLast()
        }
        return output.isEmpty ? "media" : output
    }
}

private func clipUTF8(_ text: String, maxBytes: Int) -> String {
    guard text.utf8.count > maxBytes else { return text }
    var result = ""
    var count = 0
    for scalar in text.unicodeScalars {
        let bytes = String(scalar).utf8.count
        if count + bytes > maxBytes { break }
        result.unicodeScalars.append(scalar)
        count += bytes
    }
    return result
}

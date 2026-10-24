import Foundation

enum VideoTrimmer {
    struct Request {
        var source: URL
        var start: TimeInterval
        var end: TimeInterval
        var ffmpegPath: String
        var accurate: Bool
    }

    static func export(
        _ request: Request,
        onStart: ((ProcessRunner.Handle) -> Void)? = nil,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let ffmpeg = VideoThumbnail.ffmpegExecutable(preferred: request.ffmpegPath) else {
            throw TrimFailure("找不到 ffmpeg。請先用 Homebrew 安裝，或在設定裡指定路徑。")
        }
        let length = request.end - request.start
        guard length >= 0.1 else {
            throw TrimFailure("選取的片段至少要 0.1 秒。")
        }
        guard FileManager.default.fileExists(atPath: request.source.path) else {
            throw TrimFailure("找不到原始影片。")
        }

        let audioOnly = audioExtensions.contains(request.source.pathExtension.lowercased())
        let ext = outputExtension(source: request.source, audioOnly: audioOnly, accurate: request.accurate)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("framekeep-trim-\(UUID().uuidString).\(ext)")
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }

        var args = [
            "-y",
            "-ss", time(request.start),
            "-i", request.source.path,
            "-t", time(length)
        ]
        if audioOnly {
            args += request.accurate
                ? ["-vn", "-c:a", "aac", "-b:a", "192k"]
                : ["-vn", "-c", "copy"]
        } else if request.accurate {
            args += [
                "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
                "-c:a", "aac", "-b:a", "192k",
                "-movflags", "+faststart"
            ]
        } else {
            args += ["-c", "copy", "-avoid_negative_ts", "make_zero"]
        }
        args.append(dest.path)

        let result = try await ProcessRunner.run(
            executable: ffmpeg,
            arguments: args,
            timeout: 60 * 60,
            onStart: onStart,
            onStderrLine: { line in
                guard let seconds = clockSeconds(in: line) else { return }
                onProgress(min(0.99, seconds / length))
            }
        )
        guard result.exitCode == 0, FileManager.default.fileExists(atPath: dest.path) else {
            try? FileManager.default.removeItem(at: dest)
            let lines = result.stderr.split { $0 == "\n" || $0 == "\r" }
            let tail = lines.suffix(2).joined(separator: " ")
            throw TrimFailure(tail.isEmpty ? "剪接失敗。" : "剪接失敗：\(tail)")
        }
        onProgress(1)
        return dest
    }

    static func previewJPEG(url: URL, seconds: TimeInterval, ffmpegPath: String) async -> Data? {
        guard let ffmpeg = VideoThumbnail.ffmpegExecutable(preferred: ffmpegPath) else { return nil }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("framekeep-scrub-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: dest) }
        let result = try? await ProcessRunner.run(
            executable: ffmpeg,
            arguments: [
                "-y",
                "-ss", time(seconds),
                "-i", url.path,
                "-frames:v", "1",
                "-vf", "scale=960:-2",
                "-update", "1",
                dest.path
            ],
            timeout: 20
        )
        guard result?.exitCode == 0,
              let data = try? Data(contentsOf: dest),
              !data.isEmpty
        else { return nil }
        return data
    }

    private static let audioExtensions: Set<String> = ["m4a", "mp3", "aac", "opus", "wav", "flac"]

    private static func outputExtension(source: URL, audioOnly: Bool, accurate: Bool) -> String {
        if audioOnly {
            let ext = source.pathExtension.lowercased()
            return ext == "mp3" || ext == "wav" || ext == "flac" ? ext : "m4a"
        }
        if accurate { return "mp4" }
        let ext = source.pathExtension.lowercased()
        return ext.isEmpty ? "mp4" : ext
    }

    private static func time(_ seconds: TimeInterval) -> String {
        String(format: "%.3f", max(0, seconds))
    }

    private static func clockSeconds(in line: String) -> Double? {
        guard let range = line.range(of: "time=") else { return nil }
        let token = line[range.upperBound...].prefix { !$0.isWhitespace }
        let parts = token.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2])
        else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}

struct TrimFailure: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

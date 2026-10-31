import Foundation

enum VideoTrimmer {
    struct Segment: Equatable, Identifiable, Sendable {
        var id: UUID
        var start: TimeInterval
        var end: TimeInterval

        init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval) {
            self.id = id
            self.start = start
            self.end = end
        }

        var length: TimeInterval { max(0, end - start) }
    }

    struct Request {
        var source: URL
        var segments: [Segment]
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
        let segments = request.segments.filter { $0.length >= 0.1 }
        guard !segments.isEmpty else {
            throw TrimFailure("請至少保留一段 0.1 秒以上的片段。")
        }
        guard FileManager.default.fileExists(atPath: request.source.path) else {
            throw TrimFailure("找不到原始影片。")
        }

        let totalLength = segments.reduce(0) { $0 + $1.length }
        let audioOnly = audioExtensions.contains(request.source.pathExtension.lowercased())
        let ext = outputExtension(source: request.source, audioOnly: audioOnly, accurate: request.accurate)

        if segments.count == 1 {
            return try await exportSingle(
                source: request.source,
                start: segments[0].start,
                length: segments[0].length,
                ffmpeg: ffmpeg,
                audioOnly: audioOnly,
                accurate: request.accurate,
                ext: ext,
                // Keep fast keyframe seek for the single-range path.
                seekAfterInput: false,
                onStart: onStart,
                onProgress: onProgress
            )
        }

        var partURLs: [URL] = []
        defer {
            for url in partURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        var completed: TimeInterval = 0
        // Multi-segment stream-copy needs seek-after-input so each part's
        // duration is accurate enough for concat.
        let seekAfterInput = !request.accurate
        for (index, segment) in segments.enumerated() {
            let part = FileManager.default.temporaryDirectory
                .appendingPathComponent("framekeep-trim-part-\(UUID().uuidString).\(ext)")
            try await cutSegment(
                source: request.source,
                start: segment.start,
                length: segment.length,
                destination: part,
                ffmpeg: ffmpeg,
                audioOnly: audioOnly,
                accurate: request.accurate,
                seekAfterInput: seekAfterInput,
                onStart: onStart
            ) { seconds in
                let done = completed + min(segment.length, max(0, seconds))
                onProgress(min(0.92, done / totalLength * 0.92))
            }
            guard FileManager.default.fileExists(atPath: part.path) else {
                throw TrimFailure("第 \(index + 1) 段剪接失敗。")
            }
            partURLs.append(part)
            completed += segment.length
            onProgress(min(0.92, completed / totalLength * 0.92))
        }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("framekeep-trim-\(UUID().uuidString).\(ext)")
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }

        try await concatenate(
            parts: partURLs,
            destination: dest,
            ffmpeg: ffmpeg,
            accurate: request.accurate,
            audioOnly: audioOnly,
            onStart: onStart
        )
        guard FileManager.default.fileExists(atPath: dest.path) else {
            throw TrimFailure("合成失敗。")
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

    static func makePreview(url: URL, segments: [Segment], ffmpegPath: String) async -> URL? {
        guard let ffmpeg = VideoThumbnail.ffmpegExecutable(preferred: ffmpegPath) else { return nil }
        let pieces = segments.filter { $0.length >= 0.1 }
        guard !pieces.isEmpty, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("framekeep-preview-\(UUID().uuidString).mp4")
        let budget = max(45, pieces.reduce(0) { $0 + $1.length } * 1.5)
        if await renderPreview(url: url, pieces: pieces, dest: dest, ffmpeg: ffmpeg, audio: true, timeout: budget) {
            return dest
        }
        if Task.isCancelled { return nil }
        try? FileManager.default.removeItem(at: dest)
        if await renderPreview(url: url, pieces: pieces, dest: dest, ffmpeg: ffmpeg, audio: false, timeout: budget) {
            return dest
        }
        try? FileManager.default.removeItem(at: dest)
        return nil
    }

    private static func renderPreview(
        url: URL,
        pieces: [Segment],
        dest: URL,
        ffmpeg: URL,
        audio: Bool,
        timeout: TimeInterval
    ) async -> Bool {
        let result = try? await ProcessRunner.run(
            executable: ffmpeg,
            arguments: previewArguments(url: url, pieces: pieces, dest: dest, audio: audio),
            timeout: timeout
        )
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.intValue ?? 0
        guard !Task.isCancelled, result?.exitCode == 0, size > 0 else { return false }
        return true
    }

    private static func previewArguments(url: URL, pieces: [Segment], dest: URL, audio: Bool) -> [String] {
        var args = ["-y"]
        for piece in pieces {
            args += ["-ss", time(piece.start), "-t", time(piece.length), "-i", url.path]
        }
        if pieces.count == 1 {
            args += ["-vf", "scale=960:-2", "-map", "0:v:0"]
            if audio {
                args += ["-map", "0:a:0?", "-c:a", "aac", "-b:a", "128k", "-ac", "2"]
            } else {
                args += ["-an"]
            }
        } else {
            var filters: [String] = []
            var videoInputs: [String] = []
            for index in pieces.indices {
                filters.append("[\(index):v:0]scale=960:-2,setsar=1[v\(index)]")
                videoInputs.append("[v\(index)]")
                if audio {
                    filters.append("[\(index):a:0]aformat=sample_rates=48000:channel_layouts=stereo[a\(index)]")
                }
            }
            if audio {
                let pairs = pieces.indices.map { "[v\($0)][a\($0)]" }.joined()
                filters.append("\(pairs)concat=n=\(pieces.count):v=1:a=1[v][a]")
                args += ["-filter_complex", filters.joined(separator: ";"), "-map", "[v]", "-map", "[a]", "-c:a", "aac", "-b:a", "128k"]
            } else {
                filters.append("\(videoInputs.joined())concat=n=\(pieces.count):v=1:a=0[v]")
                args += ["-filter_complex", filters.joined(separator: ";"), "-map", "[v]", "-an"]
            }
        }
        args += [
            "-c:v", "libx264",
            "-preset", "ultrafast",
            "-crf", "28",
            "-pix_fmt", "yuv420p",
            "-movflags", "+faststart",
            dest.path
        ]
        return args
    }

    private static let audioExtensions: Set<String> = ["m4a", "mp3", "aac", "opus", "wav", "flac"]

    private static func exportSingle(
        source: URL,
        start: TimeInterval,
        length: TimeInterval,
        ffmpeg: URL,
        audioOnly: Bool,
        accurate: Bool,
        ext: String,
        seekAfterInput: Bool,
        onStart: ((ProcessRunner.Handle) -> Void)?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("framekeep-trim-\(UUID().uuidString).\(ext)")
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        try await cutSegment(
            source: source,
            start: start,
            length: length,
            destination: dest,
            ffmpeg: ffmpeg,
            audioOnly: audioOnly,
            accurate: accurate,
            seekAfterInput: seekAfterInput,
            onStart: onStart
        ) { seconds in
            onProgress(min(0.99, seconds / length))
        }
        guard FileManager.default.fileExists(atPath: dest.path) else {
            throw TrimFailure("剪接失敗。")
        }
        onProgress(1)
        return dest
    }

    private static func cutSegment(
        source: URL,
        start: TimeInterval,
        length: TimeInterval,
        destination: URL,
        ffmpeg: URL,
        audioOnly: Bool,
        accurate: Bool,
        seekAfterInput: Bool,
        onStart: ((ProcessRunner.Handle) -> Void)?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }

        var args = ["-y"]
        if seekAfterInput {
            args += ["-i", source.path, "-ss", time(start), "-t", time(length)]
        } else {
            args += ["-ss", time(start), "-i", source.path, "-t", time(length)]
        }
        if audioOnly {
            args += accurate
                ? ["-vn", "-c:a", "aac", "-b:a", "192k"]
                : ["-vn", "-c", "copy"]
        } else if accurate {
            args += [
                "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
                "-c:a", "aac", "-b:a", "192k",
                "-movflags", "+faststart"
            ]
        } else {
            args += ["-c", "copy", "-avoid_negative_ts", "make_zero"]
        }
        args.append(destination.path)

        let result = try await ProcessRunner.run(
            executable: ffmpeg,
            arguments: args,
            timeout: 60 * 60,
            onStart: onStart,
            onStderrLine: { line in
                guard let seconds = clockSeconds(in: line) else { return }
                onProgress(seconds)
            }
        )
        guard result.exitCode == 0 else {
            try? FileManager.default.removeItem(at: destination)
            let lines = result.stderr.split { $0 == "\n" || $0 == "\r" }
            let tail = lines.suffix(2).joined(separator: " ")
            throw TrimFailure(tail.isEmpty ? "剪接失敗。" : "剪接失敗：\(tail)")
        }
    }

    private static func concatenate(
        parts: [URL],
        destination: URL,
        ffmpeg: URL,
        accurate: Bool,
        audioOnly: Bool,
        onStart: ((ProcessRunner.Handle) -> Void)?
    ) async throws {
        let listURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("framekeep-concat-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: listURL) }

        let listBody = parts.map { "file '\(concatPath($0.path))'" }.joined(separator: "\n") + "\n"
        try listBody.write(to: listURL, atomically: true, encoding: .utf8)

        let copyArgs = concatArguments(
            listPath: listURL.path,
            destination: destination.path,
            audioOnly: audioOnly,
            reencode: accurate
        )
        let copyResult = try await ProcessRunner.run(
            executable: ffmpeg,
            arguments: copyArgs,
            timeout: 60 * 60,
            onStart: onStart
        )
        if copyResult.exitCode == 0 { return }

        // Stream-copy concat can fail after keyframe cuts; re-encode once as fallback.
        if !accurate {
            try? FileManager.default.removeItem(at: destination)
            let reencodeArgs = concatArguments(
                listPath: listURL.path,
                destination: destination.path,
                audioOnly: audioOnly,
                reencode: true
            )
            let retry = try await ProcessRunner.run(
                executable: ffmpeg,
                arguments: reencodeArgs,
                timeout: 60 * 60,
                onStart: onStart
            )
            if retry.exitCode == 0 { return }
            try? FileManager.default.removeItem(at: destination)
            let lines = retry.stderr.split { $0 == "\n" || $0 == "\r" }
            let tail = lines.suffix(2).joined(separator: " ")
            throw TrimFailure(tail.isEmpty ? "合成失敗。" : "合成失敗：\(tail)")
        }

        try? FileManager.default.removeItem(at: destination)
        let lines = copyResult.stderr.split { $0 == "\n" || $0 == "\r" }
        let tail = lines.suffix(2).joined(separator: " ")
        throw TrimFailure(tail.isEmpty ? "合成失敗。" : "合成失敗：\(tail)")
    }

    private static func concatArguments(
        listPath: String,
        destination: String,
        audioOnly: Bool,
        reencode: Bool
    ) -> [String] {
        var args = [
            "-y",
            "-f", "concat",
            "-safe", "0",
            "-i", listPath
        ]
        if reencode {
            if audioOnly {
                args += ["-vn", "-c:a", "aac", "-b:a", "192k"]
            } else {
                args += [
                    "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
                    "-c:a", "aac", "-b:a", "192k",
                    "-movflags", "+faststart"
                ]
            }
        } else {
            args += ["-c", "copy"]
            if !audioOnly {
                args += ["-movflags", "+faststart"]
            }
        }
        args.append(destination)
        return args
    }

    private static func concatPath(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }

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

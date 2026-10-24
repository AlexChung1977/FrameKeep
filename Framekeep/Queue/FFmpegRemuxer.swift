import Foundation

struct FFmpegRemuxer {
    func remuxIfNeeded(input: URL, ffmpeg: URL, outputDirectory: URL, preferAudioOnly: Bool) async throws -> URL {
        let ext = input.pathExtension.lowercased()
        let alreadyFinal: Set<String> = preferAudioOnly ? ["m4a", "aac", "mp3", "opus"] : ["mp4", "m4v", "mov", "m4a"]
        if alreadyFinal.contains(ext) {
            return input
        }

        try AppPaths.ensureDirectory(outputDirectory)
        let destExt = preferAudioOnly ? "m4a" : "mp4"
        let dest = outputDirectory.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".\(destExt)")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }

        var args = ["-y", "-i", input.path, "-map", "0", "-c", "copy"]
        if destExt == "mp4" {
            args += ["-movflags", "+faststart"]
        }
        args.append(dest.path)

        AppLog.info("ffmpeg remux \(input.lastPathComponent) -> \(dest.lastPathComponent)")
        let result = try await ProcessRunner.run(
            executable: ffmpeg,
            arguments: args,
            timeout: 60 * 30
        )
        guard result.exitCode == 0, FileManager.default.fileExists(atPath: dest.path) else {
            throw AppError.remuxFailed(result.stderr.split(whereSeparator: \.isNewline).suffix(2).joined(separator: " "))
        }
        return dest
    }
}

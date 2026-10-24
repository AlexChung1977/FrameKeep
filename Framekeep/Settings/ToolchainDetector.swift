import Combine
import Foundation

struct ToolchainStatus: Equatable {
    var ytdlpURL: URL?
    var ffmpegURL: URL?
    var ytdlpVersion: String?
    var ffmpegVersion: String?

    var isReady: Bool { ytdlpURL != nil && ffmpegURL != nil }

    var missingNames: [String] {
        var names: [String] = []
        if ytdlpURL == nil { names.append("yt-dlp") }
        if ffmpegURL == nil { names.append("ffmpeg") }
        return names
    }
}

@MainActor
final class ToolchainDetector: ObservableObject {
    @Published private(set) var status = ToolchainStatus()
    @Published private(set) var lastChecked: Date?

    func refresh(settings: AppSettings) async {
        let ytdlp = await resolveExecutable(
            preferred: settings.ytdlpPath,
            names: ["yt-dlp"]
        )
        let ffmpeg = await resolveExecutable(
            preferred: settings.ffmpegPath,
            names: ["ffmpeg"]
        )
        var next = ToolchainStatus(ytdlpURL: ytdlp, ffmpegURL: ffmpeg, ytdlpVersion: nil, ffmpegVersion: nil)
        if let ytdlp {
            next.ytdlpVersion = await shortVersion(executable: ytdlp)
        }
        if let ffmpeg {
            next.ffmpegVersion = await shortVersion(executable: ffmpeg, arguments: ["-version"])
        }
        status = next
        lastChecked = Date()
        AppLog.info("toolchain yt-dlp=\(ytdlp?.path ?? "missing") ffmpeg=\(ffmpeg?.path ?? "missing")")
    }

    func brewInstallCommand() -> String {
        "brew install yt-dlp ffmpeg"
    }

    private func resolveExecutable(preferred: String, names: [String]) async -> URL? {
        var candidates: [String] = []
        if !preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(preferred)
        }
        for name in names {
            candidates.append(contentsOf: [
                "/opt/homebrew/bin/\(name)",
                "/usr/local/bin/\(name)",
                "/opt/local/bin/\(name)",
                "/usr/bin/\(name)"
            ])
        }
        for path in candidates {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        for name in names {
            if let found = await which(name) {
                return found
            }
        }
        return nil
    }

    private func which(_ name: String) async -> URL? {
        let shells = ["/bin/zsh", "/bin/bash"]
        for shell in shells {
            guard FileManager.default.isExecutableFile(atPath: shell) else { continue }
            do {
                let result = try await ProcessRunner.run(
                    executable: URL(fileURLWithPath: shell),
                    arguments: ["-lc", "command -v \(name)"],
                    timeout: 8
                )
                let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private func shortVersion(executable: URL, arguments: [String] = ["--version"]) async -> String? {
        do {
            let result = try await ProcessRunner.run(
                executable: executable,
                arguments: arguments,
                timeout: 8
            )
            let line = result.stdout.split(whereSeparator: \.isNewline).first.map(String.init)
                ?? result.stderr.split(whereSeparator: \.isNewline).first.map(String.init)
            return line?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}

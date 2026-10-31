import Foundation

struct YtDlpClient {
    func probe(url: URL, cookies: URL?, ytdlp: URL, ffmpeg: URL?) async throws -> ProbeResult {
        var args = [
            "--dump-json",
            "--no-download",
            "--no-playlist",
            "--no-warnings",
            "--skip-download"
        ]
        if let cookies {
            args += ["--cookies", cookies.path]
        }
        if let ffmpeg {
            args += ["--ffmpeg-location", ffmpeg.deletingLastPathComponent().path]
        }
        args.append(url.absoluteString)

        do {
            let result = try await ProcessRunner.run(
                executable: ytdlp,
                arguments: args,
                timeout: 90
            )
            guard result.exitCode == 0 else {
                throw mapFailure(stdout: result.stdout, stderr: result.stderr)
            }
            return try parseProbe(stdout: result.stdout, fallbackURL: url)
        } catch let error as AppError {
            throw error
        } catch let error as ProcessRunnerError {
            throw mapProcessError(error)
        } catch {
            throw AppError.probeFailed(error.localizedDescription)
        }
    }

    func download(
        url: URL,
        format: String,
        formatSort: String? = nil,
        outputTemplate: String,
        workDirectory: URL,
        cookies: URL?,
        ytdlp: URL,
        ffmpeg: URL?,
        onStart: @escaping (ProcessRunner.Handle) -> Void,
        onProgressLine: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        var args = [
            "--no-playlist",
            "--newline",
            "--progress",
            "--no-warnings",
            "--restrict-filenames",
            "-f", format,
            "-o", outputTemplate
        ]
        if let formatSort, !formatSort.isEmpty {
            args += ["-S", formatSort]
        }
        if FormatSelector.prefersAudioOnly(format) {
            args += ["--extract-audio", "--audio-format", "m4a"]
        } else {
            args += ["--merge-output-format", "mp4"]
        }
        if let cookies {
            args += ["--cookies", cookies.path]
        }
        if let ffmpeg {
            args += ["--ffmpeg-location", ffmpeg.deletingLastPathComponent().path]
        }
        args.append(url.absoluteString)

        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executable: ytdlp,
                arguments: args,
                currentDirectory: workDirectory,
                timeout: 60 * 60 * 6,
                onStart: onStart,
                onStdoutLine: onProgressLine,
                onStderrLine: onProgressLine
            )
        } catch let error as ProcessRunnerError {
            throw mapProcessError(error)
        }

        guard result.exitCode == 0 else {
            throw mapFailure(stdout: result.stdout, stderr: result.stderr)
        }

        if let destination = ProgressParser.destinationPath(in: result.stdout + "\n" + result.stderr) {
            let url = URL(fileURLWithPath: destination)
            if FileManager.default.fileExists(atPath: url.path) { return url }
            let relative = workDirectory.appendingPathComponent(destination)
            if FileManager.default.fileExists(atPath: relative.path) { return relative }
        }

        let files = (try? FileManager.default.contentsOfDirectory(at: workDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        if let newest = files
            .filter({ !$0.lastPathComponent.hasSuffix(".part") && !$0.pathExtension.isEmpty })
            .sorted(by: { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            })
            .first {
            return newest
        }
        throw AppError.downloadFailed("下載完成，但找不到輸出檔案。")
    }

    func parseProbe(stdout: String, fallbackURL: URL) throws -> ProbeResult {
        guard let object = firstJSONObject(in: stdout) else {
            throw AppError.probeFailed("yt-dlp 沒有回傳可用的 JSON。")
        }
        let extractor = (object["extractor"] as? String) ?? (object["extractor_key"] as? String) ?? "generic"
        let title = Self.mediaTitle(from: object, extractor: extractor, fallbackURL: fallbackURL)
        let host = fallbackURL.host ?? (object["webpage_url_domain"] as? String) ?? extractor
        let duration = (object["duration"] as? Double) ?? (object["duration"] as? Int).map(Double.init)
        let thumb = (object["thumbnail"] as? String).flatMap(URL.init(string:))
        let webpageID = object["id"] as? String
        let availability = (object["availability"] as? String)?.lowercased() ?? ""
        let formats = parseFormats(object["formats"] as? [[String: Any]] ?? [])

        var capability: Capability = formats.isEmpty ? .captureOnly : .downloadable
        var message: String?
        var requiresCookie = false

        if availability.contains("premium") || availability.contains("subscription") || availability.contains("needs_auth") {
            capability = .needsLogin
            requiresCookie = true
            message = AppError.needsLogin.localizedChinese
        }
        if let live = object["is_live"] as? Bool, live {
            capability = .captureOnly
            message = "這是直播內容，下載器不一定穩；建議改用擷取。"
        }

        return ProbeResult(
            url: (object["webpage_url"] as? String).flatMap(URL.init(string:)) ?? fallbackURL,
            title: title,
            thumbnailURL: thumb,
            duration: duration,
            sourceHost: host,
            extractor: extractor,
            formats: formats,
            requiresCookie: requiresCookie,
            capability: capability,
            message: message,
            webpageID: webpageID
        )
    }

    private static func mediaTitle(from object: [String: Any], extractor: String, fallbackURL: URL) -> String {
        let raw = trimmedText(object["title"])
        let domain = (object["webpage_url_domain"] as? String) ?? ""
        let host = (fallbackURL.host ?? domain).lowercased()
        let isInstagram = extractor.lowercased().contains("instagram") || host.contains("instagram")
        if isInstagram {
            if let raw, !isGenericInstagramTitle(raw, id: trimmedText(object["id"])) {
                return raw
            }
            if let description = trimmedText(object["description"]),
               let caption = instagramCaptionName(description) {
                return caption
            }
        }
        if let raw { return raw }
        return fallbackURL.lastPathComponent
    }

    private static func isGenericInstagramTitle(_ title: String, id: String?) -> Bool {
        if let id, title.caseInsensitiveCompare(id) == .orderedSame { return true }
        let lower = title.lowercased()
        if lower.range(of: #"^(video|post|story) by \S+$"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"^video \d+$"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// Instagram keeps the post name in the caption. Use the first real line, without a trailing tag list.
    private static func instagramCaptionName(_ description: String) -> String? {
        let lines = description
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let line = lines.first(where: { !isHashtagLine($0) }) ?? lines.first else { return nil }
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        var end = tokens.count
        while end > 0 {
            let token = tokens[end - 1]
            if token.hasPrefix("#") || token.hasPrefix("@") {
                end -= 1
            } else {
                break
            }
        }
        let name = tokens.prefix(end).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? line : name
    }

    private static func isHashtagLine(_ line: String) -> Bool {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy { $0.hasPrefix("#") || $0.hasPrefix("@") }
    }

    private static func trimmedText(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    func mapFailure(stdout: String, stderr: String) -> AppError {
        let blob = (stdout + "\n" + stderr).lowercased()
        if blob.contains("drm") || blob.contains("widevine") || blob.contains("protected with") {
            return .suspectedDRM
        }
        if blob.contains("confirm you’re not a bot") || blob.contains("confirm you're not a bot") {
            return .botCheck
        }
        if blob.contains("sign in") || blob.contains("login") || blob.contains("private video")
            || blob.contains("cookies") && blob.contains("age")
            || blob.contains("available to everyone") || blob.contains("certain audiences")
            || blob.contains("restricted video") {
            return .needsLogin
        }
        if blob.contains("unsupported url") || blob.contains("no suitable") && blob.contains("extractor") {
            return .unsupported
        }
        if blob.contains("http error 403") || blob.contains("http error 429") || blob.contains("blocked") {
            return .policyBlocked(humanTail(stdout: stdout, stderr: stderr))
        }
        if blob.contains("no space") || blob.contains("not enough space") {
            return .diskSpace
        }
        return .probeFailed(humanTail(stdout: stdout, stderr: stderr))
    }

    private func mapProcessError(_ error: ProcessRunnerError) -> AppError {
        switch error {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .probeFailed("解析逾時。")
        case .executableNotFound(let path):
            return .toolMissing(path)
        case .nonZeroExit(_, let stderr):
            return mapFailure(stdout: "", stderr: stderr)
        }
    }

    private func humanTail(stdout: String, stderr: String) -> String {
        let lines = (stderr + "\n" + stdout)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty, !line.hasPrefix("[debug]") else { return false }
                let lower = line.lowercased()
                if lower.hasPrefix("deprecated feature") { return false }
                if lower.hasPrefix("please remove them from your command") { return false }
                if lower.contains("yt-dlp/issues/14198") { return false }
                return true
            }
        let errors = lines.filter { $0.hasPrefix("ERROR:") }
        let chosen = errors.last ?? lines.last
        guard let chosen else { return "未知錯誤" }
        if let range = chosen.range(of: #"^ERROR:\s*(\[[^\]]+\]\s*)?[^:]+:\s*"#, options: .regularExpression) {
            let detail = String(chosen[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !detail.isEmpty { return detail }
        }
        return chosen
    }

    private func parseFormats(_ raw: [[String: Any]]) -> [MediaFormat] {
        var seen = Set<String>()
        var formats: [MediaFormat] = []
        for item in raw {
            guard let id = item["format_id"] as? String, seen.insert(id).inserted else { continue }
            let ext = (item["ext"] as? String) ?? "mp4"
            let vcodec = item["vcodec"] as? String
            let acodec = item["acodec"] as? String
            let height = intValue(item["height"])
            let width = intValue(item["width"])
            let isAudio = (vcodec == nil || vcodec == "none") && acodec != nil && acodec != "none"
            let isVideoOnly = (acodec == nil || acodec == "none") && vcodec != nil && vcodec != "none"
            let note = (item["format_note"] as? String) ?? (item["quality"] as? String)
            let resolution = height.map { "\($0)p" } ?? (item["resolution"] as? String) ?? ext
            let labelParts = [resolution, note, ext.uppercased()].compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            let filesize = int64Value(item["filesize"]) ?? int64Value(item["filesize_approx"])
            formats.append(
                MediaFormat(
                    id: id,
                    label: labelParts.joined(separator: " · "),
                    height: height,
                    width: width,
                    ext: ext,
                    vcodec: vcodec,
                    acodec: acodec,
                    filesize: filesize,
                    fps: doubleValue(item["fps"]),
                    abr: doubleValue(item["abr"]),
                    note: note,
                    isAudioOnly: isAudio,
                    isVideoOnly: isVideoOnly
                )
            )
        }
        return formats.sorted { lhs, rhs in
            (lhs.height ?? (lhs.isAudioOnly ? -1 : 0)) > (rhs.height ?? (rhs.isAudioOnly ? -1 : 0))
        }
    }

    private func firstJSONObject(in text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        for line in trimmed.split(whereSeparator: \.isNewline).reversed() {
            let piece = line.trimmingCharacters(in: .whitespaces)
            guard piece.hasPrefix("{"),
                  let data = piece.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            return object
        }
        if let start = trimmed.firstIndex(of: "{"),
           let data = String(trimmed[start...]).data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        return nil
    }

    private func intValue(_ raw: Any?) -> Int? {
        if let v = raw as? Int { return v }
        if let v = raw as? Double { return Int(v) }
        if let v = raw as? String { return Int(v) }
        return nil
    }

    private func int64Value(_ raw: Any?) -> Int64? {
        if let v = raw as? Int64 { return v }
        if let v = raw as? Int { return Int64(v) }
        if let v = raw as? Double { return Int64(v) }
        return nil
    }

    private func doubleValue(_ raw: Any?) -> Double? {
        if let v = raw as? Double { return v }
        if let v = raw as? Int { return Double(v) }
        return nil
    }
}

struct YouTubeAdapter: ExtractorAdapter {
    let name = "YouTube"
    let client: YtDlpClient

    func canHandle(url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.contains("youtube.com") || host.contains("youtu.be") || host.contains("youtube-nocookie.com")
    }

    func probe(url: URL, cookies: URL?, ytdlp: URL, ffmpeg: URL?) async throws -> ProbeResult {
        try await client.probe(url: url, cookies: cookies, ytdlp: ytdlp, ffmpeg: ffmpeg)
    }
}

struct YtDlpGenericAdapter: ExtractorAdapter {
    let name = "yt-dlp generic"
    let client: YtDlpClient

    func canHandle(url: URL) -> Bool {
        url.scheme == "http" || url.scheme == "https"
    }

    func probe(url: URL, cookies: URL?, ytdlp: URL, ffmpeg: URL?) async throws -> ProbeResult {
        try await client.probe(url: url, cookies: cookies, ytdlp: ytdlp, ffmpeg: ffmpeg)
    }
}

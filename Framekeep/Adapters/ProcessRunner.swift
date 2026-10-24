import Foundation

enum ProcessRunnerError: LocalizedError {
    case executableNotFound(String)
    case nonZeroExit(code: Int32, stderr: String)
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            return "找不到執行檔：\(path)"
        case .nonZeroExit(let code, let stderr):
            let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if tail.isEmpty { return "程序結束代碼 \(code)" }
            return tail
        case .timedOut:
            return "程序逾時。"
        case .cancelled:
            return "程序已取消。"
        }
    }
}

struct ProcessResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Isolated child-process runner. Never scrapes inside the UI process.
enum ProcessRunner {
    struct Handle: @unchecked Sendable {
        let process: Process

        func pause() {
            _ = process.suspend()
        }

        func resume() {
            _ = process.resume()
        }

        func terminate() {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    @discardableResult
    static func run(
        executable: URL,
        arguments: [String],
        extraEnvironment: [String: String] = [:],
        currentDirectory: URL? = nil,
        timeout: TimeInterval? = 180,
        onStart: ((Handle) -> Void)? = nil,
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ProcessRunnerError.executableNotFound(executable.path)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        var env = ProcessInfo.processInfo.environment
        let brewPaths = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin"
        if let existing = env["PATH"], !existing.isEmpty {
            env["PATH"] = brewPaths + ":" + existing
        } else {
            env["PATH"] = brewPaths
        }
        extraEnvironment.forEach { env[$0.key] = $0.value }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutLock = NSLock()
        let stderrLock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stdoutLock.lock()
            stdoutData.append(chunk)
            stdoutLock.unlock()
            emitLines(from: chunk, handler: onStdoutLine)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrLock.lock()
            stderrData.append(chunk)
            stderrLock.unlock()
            emitLines(from: chunk, handler: onStderrLine)
        }

        AppLog.info("spawn \(executable.lastPathComponent) \(AppLog.redactCookies(arguments))")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let settled = Settlement()
                process.terminationHandler = { proc in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    if let extra = try? stdoutPipe.fileHandleForReading.readToEnd() { stdoutData.append(extra) }
                    if let extra = try? stderrPipe.fileHandleForReading.readToEnd() { stderrData.append(extra) }
                    stdoutLock.lock()
                    let out = String(data: stdoutData, encoding: .utf8) ?? ""
                    stdoutLock.unlock()
                    stderrLock.lock()
                    let err = String(data: stderrData, encoding: .utf8) ?? ""
                    stderrLock.unlock()
                    let result = ProcessResult(exitCode: proc.terminationStatus, stdout: out, stderr: err)
                    settled.resume(with: .success(result), continuation: continuation)
                }

                do {
                    try process.run()
                    onStart?(Handle(process: process))
                } catch {
                    settled.resume(with: .failure(error), continuation: continuation)
                    return
                }

                if let timeout {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                        guard process.isRunning else { return }
                        process.terminate()
                        settled.resume(with: .failure(ProcessRunnerError.timedOut), continuation: continuation)
                    }
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    private static func emitLines(from data: Data, handler: (@Sendable (String) -> Void)?) {
        guard let handler, let text = String(data: data, encoding: .utf8) else { return }
        text.split(whereSeparator: \.isNewline).forEach { handler(String($0)) }
    }
}

private final class Settlement: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume<T>(with result: Result<T, Error>, continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(with: result)
    }
}

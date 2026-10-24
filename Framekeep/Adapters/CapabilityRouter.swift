import Foundation

struct RouteDecision {
    let request: IngestRequest
    let probe: ProbeResult?
    let error: AppError?
    let capability: Capability

    var suggestsCapture: Bool {
        capability.suggestsCapture || (error?.suggestsCapture ?? false)
    }

    var statusChinese: String {
        if let error { return error.localizedChinese }
        if let message = probe?.message, !message.isEmpty { return message }
        return capability.title
    }
}

struct CapabilityRouter {
    let registry: ExtractorRegistry

    init(client: YtDlpClient = YtDlpClient()) {
        registry = ExtractorRegistry(ytdlpClient: client)
    }

    func route(
        request: IngestRequest,
        cookies: URL?,
        ytdlp: URL,
        ffmpeg: URL?
    ) async -> RouteDecision {
        let adapter = registry.adapter(for: request.url)
        AppLog.info("route host=\(request.url.host ?? "?") adapter=\(adapter.name)")
        do {
            let probe = try await adapter.probe(
                url: request.url,
                cookies: cookies,
                ytdlp: ytdlp,
                ffmpeg: ffmpeg
            )
            return RouteDecision(
                request: request,
                probe: probe,
                error: probe.capability == .downloadable ? nil : mapCapability(probe.capability),
                capability: probe.capability
            )
        } catch let error as AppError {
            return RouteDecision(
                request: request,
                probe: nil,
                error: error,
                capability: capability(for: error)
            )
        } catch {
            let wrapped = AppError.probeFailed(error.localizedDescription)
            return RouteDecision(
                request: request,
                probe: nil,
                error: wrapped,
                capability: .captureOnly
            )
        }
    }

    private func capability(for error: AppError) -> Capability {
        switch error {
        case .needsLogin: return .needsLogin
        case .suspectedDRM: return .suspectedDRM
        case .unsupported: return .unsupported
        case .policyBlocked: return .captureOnly
        default: return .captureOnly
        }
    }

    private func mapCapability(_ capability: Capability) -> AppError? {
        switch capability {
        case .downloadable: return nil
        case .needsLogin: return .needsLogin
        case .suspectedDRM: return .suspectedDRM
        case .unsupported: return .unsupported
        case .captureOnly: return .unsupported
        }
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var app: AppState
    @FocusState private var urlFocused: Bool
    @State private var previousURLText = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("貼上連結即開始下載", text: $app.urlText)
                        .textFieldStyle(.plain)
                        .font(FKFont.body(14))
                        .foregroundStyle(FKColor.paper)
                        .focused($urlFocused)
                        .onSubmit { Task { await app.continueIngest() } }
                    AmberButton(
                        title: app.isProbing ? "解析中…" : "下載",
                        enabled: !app.isProbing
                    ) {
                        submitField()
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .fkCard(corner: 10)

                if let banner = app.banner, !banner.isEmpty {
                    BannerView(text: banner)
                    if shouldOfferCapture(banner) {
                        AmberButton(title: "改用擷取", prominent: false) {
                            app.selected = .capture
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            QueueView()
        }
        .background(FKColor.graphite)
        .onDrop(of: [.url, .plainText], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .onChange(of: app.urlText) { text in
            handleURLChange(text)
        }
        .onAppear {
            previousURLText = app.urlText
            DispatchQueue.main.async { urlFocused = true }
        }
    }

    private func submitField() {
        if app.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            app.pasteFromClipboard()
        }
        Task { await app.continueIngest(source: .manual) }
    }

    private func handleURLChange(_ text: String) {
        let previous = previousURLText
        previousURLText = text
        if app.isProbing || app.consumeURLAutostartSuppression() { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URLIngestService.normalize(trimmed) != nil else { return }
        let jump = text.count - previous.count
        let appended = text.hasPrefix(previous)
        let fromClipboard = clipboardMatches(trimmed)
            && trimmed.count >= 4
            && (previous.isEmpty || !appended)
        let bulkInsert = appended && jump >= 8
        guard bulkInsert || fromClipboard else { return }
        Task { await app.continueIngest(source: .clipboard) }
    }

    private func clipboardMatches(_ text: String) -> Bool {
        guard let pasted = URLIngestService.pasteboardURLString(),
              let pastedURL = URLIngestService.normalize(pasted),
              let fieldURL = URLIngestService.normalize(text) else { return false }
        return pastedURL.absoluteString == fieldURL.absoluteString
    }

    private func shouldOfferCapture(_ banner: String) -> Bool {
        banner.contains("擷取") || banner.contains("DRM") || banner.contains("登入") || banner.contains("不支援") || banner.contains("阻擋")
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async {
                        app.urlText = url.absoluteString
                        Task { await app.continueIngest(source: .dragDrop) }
                    }
                }
                handled = true
            } else if provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                    guard let text = value as? String else { return }
                    DispatchQueue.main.async {
                        app.urlText = text
                        Task { await app.continueIngest(source: .dragDrop) }
                    }
                }
                handled = true
            }
        }
        return handled
    }
}

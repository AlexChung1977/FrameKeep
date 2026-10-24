import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var queue: DownloadQueueService
    @FocusState private var urlFocused: Bool

    var body: some View {
        ZStack {
            AtmosphereBackground()
            VStack(spacing: 0) {
                Spacer(minLength: 48)
                VStack(spacing: 14) {
                    Text("FRAMEKEEP")
                        .font(FKFont.display(44, weight: .semibold))
                        .foregroundStyle(FKColor.paper)
                        .tracking(4)
                    Text("貼上連結，收進本地。")
                        .font(FKFont.body(20, weight: .medium))
                        .foregroundStyle(FKColor.paper)
                    Text("能抓就下；不能就錄。")
                        .font(FKFont.body(14))
                        .foregroundStyle(FKColor.paperMuted)
                }
                .padding(.bottom, 28)

                HStack(spacing: 8) {
                    TextField("https://…", text: $app.urlText)
                        .textFieldStyle(.plain)
                        .font(FKFont.body(14))
                        .foregroundStyle(FKColor.paper)
                        .focused($urlFocused)
                        .onSubmit { Task { await app.continueIngest() } }
                    AmberButton(
                        title: app.isProbing ? "解析中…" : "繼續",
                        enabled: !app.isProbing && !app.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) {
                        Task { await app.continueIngest() }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 560)
                .fkCard(corner: 10)

                Button {
                    app.pasteFromClipboard()
                    urlFocused = true
                } label: {
                    Text("⌘V 從剪貼簿貼上")
                        .font(FKFont.body(12))
                        .foregroundStyle(FKColor.paperFaint)
                }
                .buttonStyle(.plain)
                .padding(.top, 10)

                if let banner = app.banner, !banner.isEmpty {
                    BannerView(text: banner)
                        .frame(maxWidth: 560)
                        .padding(.top, 16)
                    if shouldOfferCapture(banner) {
                        AmberButton(title: "改用擷取", prominent: false) {
                            app.selected = .capture
                        }
                        .padding(.top, 8)
                    }
                }

                if let job = queue.latestJob {
                    Button {
                        app.selected = .queue
                    } label: {
                        Text("最近任務：\(job.title) · \(job.state.title)")
                            .font(FKFont.body(12))
                            .foregroundStyle(FKColor.amber)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 22)
                }

                Spacer()
            }
            .padding(.horizontal, 40)
        }
        .onDrop(of: [.url, .plainText], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .onAppear {
            DispatchQueue.main.async { urlFocused = true }
        }
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
                    }
                }
                handled = true
            }
        }
        return handled
    }
}

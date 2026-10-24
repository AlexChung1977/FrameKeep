import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var toolchain: ToolchainDetector
    @State private var showingLimits = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("儲存") {
                    labeled("媒體庫資料夾") {
                        HStack {
                            Text(settings.moviesRootPath)
                                .font(FKFont.body(12))
                                .foregroundStyle(FKColor.paperMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            AmberButton(title: "選擇…", prominent: false, action: app.chooseMoviesRoot)
                        }
                    }
                    labeled("檔名模板") {
                        TextField("%(title)s [%(id)s].%(ext)s", text: $settings.filenameTemplate)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                section("格式") {
                    Picker("預設用途", selection: $settings.defaultFormat) {
                        ForEach(DefaultFormatPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    Stepper(value: $settings.concurrency, in: 1...2) {
                        Text("並行下載：\(settings.concurrency)")
                            .foregroundStyle(FKColor.paper)
                    }
                }

                section("隱私") {
                    Toggle("自動讀取剪貼簿中的連結", isOn: $settings.watchClipboard)
                    Toggle("保留佇列歷史", isOn: $settings.retainHistory)
                    labeled("Cookie 檔（cookies.txt）") {
                        HStack {
                            Text(settings.cookieFilePath.isEmpty ? "尚未匯入" : settings.cookieFilePath)
                                .font(FKFont.body(12))
                                .foregroundStyle(FKColor.paperMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            AmberButton(title: "匯入…", prominent: false, action: app.importCookieFile)
                            if !settings.cookieFilePath.isEmpty {
                                GhostButton(title: "清除") { settings.clearCookieFile() }
                            }
                        }
                    }
                    Text("只接受你自己從瀏覽器匯出的 cookies.txt。Framekeep 不會讀取或儲存密碼，也不會代登。")
                        .font(FKFont.body(11))
                        .foregroundStyle(FKColor.paperFaint)
                }

                section("進階工具路徑") {
                    toolRow(title: "yt-dlp", path: $settings.ytdlpPath, detected: toolchain.status.ytdlpURL?.path)
                    toolRow(title: "ffmpeg", path: $settings.ffmpegPath, detected: toolchain.status.ffmpegURL?.path)
                    HStack {
                        AmberButton(title: "重新偵測", prominent: false) {
                            Task { await toolchain.refresh(settings: settings) }
                        }
                        if let ytdlp = toolchain.status.ytdlpVersion {
                            Text(ytdlp).font(FKFont.body(11)).foregroundStyle(FKColor.paperFaint)
                        }
                    }
                }

                section("擷取") {
                    Toggle("預設一併錄麥克風", isOn: $settings.includeMicrophoneByDefault)
                }

                section("瀏覽器右鍵") {
                    Text("在 Chrome、Edge 或 Brave 載入擴充功能後，網頁、連結或影片上按右鍵，可選「用 Framekeep 下載」。會打開 Framekeep 並解析這個網址。")
                        .font(FKFont.body(12))
                        .foregroundStyle(FKColor.paperMuted)
                    AmberButton(title: "安裝並顯示擴充功能", prominent: false) {
                        let folder = BrowserBridge.install()
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                        app.banner = "已安裝瀏覽器連接。請在擴充功能頁面載入這個資料夾。"
                    }
                }

                section("關於與限制") {
                    Text("Framekeep 0.1.0 · 個人本機工具，非 Mac App Store 發行。")
                        .font(FKFont.body(12))
                        .foregroundStyle(FKColor.paperMuted)
                    AmberButton(title: "我們不支援什麼", prominent: false) {
                        showingLimits = true
                    }
                }
            }
            .padding(22)
        }
        .background(FKColor.graphite)
        .foregroundStyle(FKColor.paper)
        .sheet(isPresented: $showingLimits) {
            AboutLimitsView()
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(FKFont.display(16, weight: .semibold))
                .foregroundStyle(FKColor.paper)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fkCard(corner: 10)
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(FKFont.body(12, weight: .medium))
                .foregroundStyle(FKColor.paperMuted)
            content()
        }
    }

    private func toolRow(title: String, path: Binding<String>, detected: String?) -> some View {
        labeled(title) {
            HStack {
                TextField(detected ?? "自動偵測", text: path)
                    .textFieldStyle(.roundedBorder)
                AmberButton(title: "瀏覽…", prominent: false) {
                    app.chooseTool(title: "選擇 \(title)") { url in
                        path.wrappedValue = url.path
                    }
                }
            }
        }
    }
}

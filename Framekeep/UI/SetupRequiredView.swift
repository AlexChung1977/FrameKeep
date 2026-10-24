import AppKit
import SwiftUI

struct SetupRequiredView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var toolchain: ToolchainDetector

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("需要本機工具")
                .font(FKFont.display(22, weight: .semibold))
                .foregroundStyle(FKColor.paper)
            Text("Framekeep 以獨立子程序呼叫 yt-dlp 與 ffmpeg，不會在 App 內爬站或繞過 DRM。請先安裝這兩個命令列工具。")
                .font(FKFont.body(13))
                .foregroundStyle(FKColor.paperMuted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                statusRow(name: "yt-dlp", ok: toolchain.status.ytdlpURL != nil, detail: toolchain.status.ytdlpURL?.path)
                statusRow(name: "ffmpeg", ok: toolchain.status.ffmpegURL != nil, detail: toolchain.status.ffmpegURL?.path)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Homebrew")
                    .font(FKFont.body(12, weight: .medium))
                    .foregroundStyle(FKColor.paperMuted)
                HStack {
                    Text(toolchain.brewInstallCommand())
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(FKColor.paper)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(FKColor.graphitePanel)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    AmberButton(title: "複製") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(toolchain.brewInstallCommand(), forType: .string)
                    }
                }
            }

            Text("若已安裝但仍偵測不到，可到設定指定絕對路徑（常見於 /opt/homebrew/bin）。")
                .font(FKFont.body(12))
                .foregroundStyle(FKColor.paperFaint)

            HStack {
                AmberButton(title: "重新偵測") {
                    Task {
                        await toolchain.refresh(settings: settings)
                        app.showingSetup = !toolchain.status.isReady
                    }
                }
                AmberButton(title: "開啟設定", prominent: false) {
                    app.showingSetup = false
                    app.selected = .settings
                }
                GhostButton(title: "稍後") {
                    app.showingSetup = false
                }
            }
        }
        .padding(24)
        .frame(minWidth: 520)
        .background(FKColor.graphite)
    }

    private func statusRow(name: String, ok: Bool, detail: String?) -> some View {
        HStack {
            Circle()
                .fill(ok ? FKColor.success : FKColor.danger)
                .frame(width: 8, height: 8)
            Text(name)
                .foregroundStyle(FKColor.paper)
            Spacer()
            Text(ok ? (detail ?? "已找到") : "未找到")
                .font(FKFont.body(12))
                .foregroundStyle(FKColor.paperMuted)
        }
    }
}

import SwiftUI

struct AboutLimitsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("我們不支援什麼")
                .font(FKFont.display(20, weight: .semibold))
                .foregroundStyle(FKColor.paper)

            limit("平台服務條款", "許多平台禁止自動化下載。請自行遵守 ToS 與著作權；Framekeep 只是本機便利工具。")
            limit("DRM／加密媒體", "不解密、不規避 Widevine 或其他 DRM。遇到受保護內容時，只會誠實告知並建議合法播放＋螢幕擷取。")
            limit("驗證碼與反機器人", "不提供繞過指導。解析失敗時可匯入你自己的 cookies.txt，或改用擷取。")
            limit("私密／付費內容", "僅在你已合法登入、且有權存取的前提下輔助。不代管帳密、不竊取瀏覽器密碼。")
            limit("大規模爬站", "MVP 只處理單一 URL，不做頻道／站點批量爬取。")

            Text("擷取模式使用系統 ScreenCaptureKit，仍可能受 HDCP 或系統政策限制。")
                .font(FKFont.body(12))
                .foregroundStyle(FKColor.paperFaint)

            HStack {
                Spacer()
                AmberButton(title: "關閉") { dismiss() }
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(FKColor.graphite)
    }

    private func limit(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(FKFont.body(13, weight: .semibold))
                .foregroundStyle(FKColor.amber)
            Text(body)
                .font(FKFont.body(12))
                .foregroundStyle(FKColor.paperMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

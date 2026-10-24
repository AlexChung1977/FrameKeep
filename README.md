# Framekeep

macOS 原生 App：貼上連結就能收進本地媒體庫。**能抓就下，不能就錄。**

這是個人／直接安裝用的工具（**不是 Mac App Store**、**沒有 App Sandbox**）。下載引擎是獨立子程序呼叫的 `yt-dlp` 與 `ffmpeg`，不會在 App 內爬站、不會解密 DRM、不會竊取瀏覽器密碼。

## 在 Xcode 開啟

最低需求：**macOS 13.0+**、**Xcode 15+**、**Swift 5.9+**。Apple Silicon 優先，Intel 也可編譯。

### 方式 A：直接開專案（建議）

```bash
open /path/to/framekeep/Framekeep.xcodeproj
```

選 scheme `Framekeep`，目標選「My Mac」，⌘R 執行。

### 方式 B：用 XcodeGen 重建專案

若 `Framekeep.xcodeproj` 在合併後異常，可依 `project.yml` 重新產生：

```bash
brew install xcodegen
cd /path/to/framekeep
xcodegen generate
open Framekeep.xcodeproj
```

簽名：本機跑可選你的個人 Team（Signing & Capabilities）。Hardened Runtime 已開啟，方便日後個人公證；**不要**打開 App Sandbox。

## 必裝命令列工具

Framekeep 只把 `yt-dlp`、`ffmpeg` 當獨立子程序跑。GUI App 的 `PATH` 很窄，安裝後常見路徑是 `/opt/homebrew/bin`。

```bash
brew install yt-dlp ffmpeg
```

若啟動時看到「需要本機工具」畫面，把上面指令貼到終端機執行，再按「重新偵測」。也可以在設定裡指定絕對路徑。

## 系統權限

| 權限 | 何時需要 | 系統設定位置 |
|------|----------|--------------|
| **螢幕錄製** | 擷取模式（畫面＋系統音訊） | 系統設定 → 隱私權與安全性 → 螢幕錄製 |
| **麥克風** | 只有勾選「麥克風」時 | 系統設定 → 隱私權與安全性 → 麥克風 |

下載一般公開內容**不需要**這些權限。

## 使用流程

1. 首頁貼上 URL → **繼續**（⌘↩）
2. 解析成功：選用途（最佳／平衡／僅音訊／自訂）→ **加入佇列**
3. 解析失敗、需登入、疑似 DRM：畫面會用中文說明，並建議 **改用擷取**
4. 擷取：先在瀏覽器播放內容 → 授權螢幕錄製 → 開始／暫停／停止 → 檔案進同一媒體庫
5. Cookie：設定頁只能**匯入你自己匯出的 cookies.txt**，不讀瀏覽器密碼

預設媒體目錄：`~/Movies/Framekeep/`（可在設定更改）。任務與媒體中繼資料存在 `~/Library/Application Support/Framekeep/db.sqlite`。

## 已知限制（誠實）

- 許多平台的服務條款**禁止自動化下載**。請自行遵守 ToS 與著作權。
- **不支援 DRM 解密或規避**（含 Widevine）。受保護內容只能合法播放後擷取，且擷取仍可能被 HDCP／系統政策擋住。
- **不繞過驗證碼、反機器人、付費牆**。
- 不代管帳密、不從瀏覽器偷 cookie。
- MVP 只處理**單一 URL**，沒有播放清單／頻道批次。
- 此原始碼在 Linux 上**無法編譯或執行**；必須在 Mac 用 Xcode 建置。

## 專案結構

```
Framekeep/
  App/           殼層、主題、狀態
  Ingest/        URL 正規化與剪貼簿
  Adapters/      yt-dlp / 通用串流 / Capability Router
  Queue/         任務狀態機、進度解析、FFmpeg remux
  Library/       媒體庫
  Capture/       ScreenCaptureKit 擷取
  Settings/      偏好與工具偵測
  Persistence/   SQLite、路徑、日誌
  UI/            六個主畫面
```

視覺：石墨 `#1A1C1E` + 琥珀 `#E0A84A`。若系統有安裝 Familjen Grotesk / Noto Sans TC 會優先使用，否則走系統字。

## 授權與責任

個人本機使用。作者不協助繞過 DRM、驗證碼或平台封鎖。使用下載功能前，請確認你有權存取該內容。

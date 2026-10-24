import AppKit
import Foundation

enum BrowserLink {
    static func pageURL(from url: URL) -> String? {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" {
            return url.absoluteString
        }
        guard scheme == "framekeep" else { return nil }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let value = components.queryItems?.first(where: { $0.name == "url" })?.value {
            let page = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if page.hasPrefix("http://") || page.hasPrefix("https://") {
                return page
            }
        }
        return nil
    }
}

final class BrowserLinkCenter {
    static let shared = BrowserLinkCenter()
    private var handler: ((URL) -> Void)?
    private var pending: [URL] = []

    func receive(_ urls: [URL]) {
        if let handler {
            urls.forEach(handler)
        } else {
            pending.append(contentsOf: urls)
        }
    }

    func bind(_ handler: @escaping (URL) -> Void) {
        self.handler = handler
        let queued = pending
        pending.removeAll()
        queued.forEach(handler)
    }
}

enum BrowserBridge {
    static let extensionID = "kgicbiddlncoicopmhfcdaoocccinneg"
    static let hostName = "app.framekeep.browser"
    private static let publicKey = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA8GJHF3oRSYdoUViUyHks/mFetxwDlyIEWmbZblTEeVUJDtzXkBpzKdu2DJlcr2EUUQ4t/xenFxOx0c5pZP/tcy5ETiHKLLKh9IM/BCnSm5v+5uWqoBg7Axlu1RtgwRSCBmvqWx7T+mYsqhVfFOSs+FYmN+MhSqs9DFpmvTHR/tmvHXl8Ngx7Fmg6qn9Iwz82ys6Fn4N6A36gqcrP0Cs6tLbynTyv1b9HuP17Fb8SNImFO8mQybMqtxwgKdMzPh9IU+tIvnukhSH+Pn6EvRe/j8tdBEML6xRLIJqlWe92U+VCyvfVdLpYP9razmHw9aHoVUhAzhUCaOZ2U9BEInYWfwIDAQAB"

    @discardableResult
    static func install() -> URL {
        let root = AppPaths.applicationSupport
        let extensionFolder = root.appendingPathComponent("BrowserExtension", isDirectory: true)
        let host = root.appendingPathComponent("framekeep-browser-host")
        try? AppPaths.ensureDirectory(extensionFolder)
        try? manifest.write(to: extensionFolder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try? backgroundJS.write(to: extensionFolder.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        try? launchHTML.write(to: extensionFolder.appendingPathComponent("launch.html"), atomically: true, encoding: .utf8)
        try? launchJS.write(to: extensionFolder.appendingPathComponent("launch.js"), atomically: true, encoding: .utf8)
        try? hostScript.write(to: host, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host.path)
        installNativeManifests(hostPath: host.path)
        return extensionFolder
    }

    private static func installNativeManifests(hostPath: String) {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let chromium = """
        {
          "name": "\(hostName)",
          "description": "Send the current page to Framekeep",
          "path": "\(hostPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))",
          "type": "stdio",
          "allowed_origins": ["chrome-extension://\(extensionID)/"]
        }
        """
        let firefox = """
        {
          "name": "\(hostName)",
          "description": "Send the current page to Framekeep",
          "path": "\(hostPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))",
          "type": "stdio",
          "allowed_extensions": ["framekeep@framekeep.app"]
        }
        """
        let chromiumDirs = [
            "Google/Chrome/NativeMessagingHosts",
            "Google/Chrome Beta/NativeMessagingHosts",
            "Google/Chrome Canary/NativeMessagingHosts",
            "Chromium/NativeMessagingHosts",
            "Microsoft Edge/NativeMessagingHosts",
            "BraveSoftware/Brave-Browser/NativeMessagingHosts",
            "Vivaldi/NativeMessagingHosts",
            "com.operasoftware.Opera/NativeMessagingHosts",
            "Arc/User Data/NativeMessagingHosts"
        ]
        for relative in chromiumDirs {
            writeManifest(chromium, name: hostName, directory: support.appendingPathComponent(relative, isDirectory: true))
        }
        writeManifest(firefox, name: hostName, directory: support.appendingPathComponent("Mozilla/NativeMessagingHosts", isDirectory: true))
    }

    private static func writeManifest(_ json: String, name: String, directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? json.write(to: directory.appendingPathComponent("\(name).json"), atomically: true, encoding: .utf8)
    }

    private static var manifest: String {
        """
        {
          "manifest_version": 3,
          "name": "Framekeep",
          "version": "0.1.0",
          "description": "在網頁按右鍵，用 Framekeep 下載。",
          "key": "\(publicKey)",
          "permissions": ["contextMenus", "nativeMessaging"],
          "background": {
            "service_worker": "background.js"
          },
          "action": {
            "default_title": "Framekeep"
          },
          "browser_specific_settings": {
            "gecko": {
              "id": "framekeep@framekeep.app"
            }
          }
        }
        """
    }

    private static let backgroundJS = """
    const HOST = "app.framekeep.browser";

    function choose(info) {
      const link = info.linkUrl || "";
      const src = info.srcUrl || "";
      const page = info.pageUrl || "";
      const selected = (info.selectionText || "").trim();
      if (link.startsWith("http://") || link.startsWith("https://")) return link;
      if (selected.startsWith("http://") || selected.startsWith("https://")) return selected;
      if (/^https?:\\/\\/.+\\.(mp4|webm|mkv|mov|m4v|m4a|mp3)(\\?|$)/i.test(src)) return src;
      if (page.startsWith("http://") || page.startsWith("https://")) return page;
      if (src.startsWith("http://") || src.startsWith("https://")) return src;
      return "";
    }

    function installMenu() {
      chrome.contextMenus.removeAll(() => {
        chrome.contextMenus.create({
          id: "framekeep-download",
          title: "用 Framekeep 下載",
          contexts: ["page", "link", "video", "audio", "selection"]
        });
      });
    }

    chrome.runtime.onInstalled.addListener(installMenu);
    installMenu();

    chrome.contextMenus.onClicked.addListener((info) => {
      const url = choose(info);
      if (!url) return;
      chrome.runtime.sendNativeMessage(HOST, { url }, (response) => {
        const failed = chrome.runtime.lastError || !response || response.ok !== true;
        if (!failed) return;
        const target = "framekeep://download?url=" + encodeURIComponent(url);
        chrome.tabs.create({
          url: chrome.runtime.getURL("launch.html") + "?target=" + encodeURIComponent(target)
        });
      });
    });
    """

    private static let launchHTML = """
    <!DOCTYPE html>
    <meta charset="utf-8">
    <title>Framekeep</title>
    <script src="launch.js"></script>
    """

    private static let launchJS = """
    const target = new URLSearchParams(location.search).get("target");
    if (target) location.replace(target);
    setTimeout(() => window.close(), 800);
    """

    private static let hostScript = """
    #!/usr/bin/python3
    import json
    import struct
    import subprocess
    import sys
    from urllib.parse import quote

    def read_message():
        raw = sys.stdin.buffer.read(4)
        if len(raw) < 4:
            return None
        size = struct.unpack("<I", raw)[0]
        if size <= 0 or size > 1_000_000:
            return None
        data = sys.stdin.buffer.read(size)
        return json.loads(data.decode("utf-8"))

    def write_message(payload):
        data = json.dumps(payload).encode("utf-8")
        sys.stdout.buffer.write(struct.pack("<I", len(data)))
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()

    message = read_message()
    page = message.get("url") if isinstance(message, dict) else None
    ok = False
    if isinstance(page, str) and (page.startswith("http://") or page.startswith("https://")):
        target = "framekeep://download?url=" + quote(page, safe="")
        subprocess.run(["/usr/bin/open", target], check=False)
        ok = True
    write_message({"ok": ok})
    """
}

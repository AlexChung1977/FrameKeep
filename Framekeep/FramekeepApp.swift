import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct FramekeepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        Window("Framekeep", id: "main") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appState.settings)
                .environmentObject(appState.queue)
                .environmentObject(appState.library)
                .environmentObject(appState.capture)
                .environmentObject(appState.toolchain)
                .frame(minWidth: 920, minHeight: 600)
                .preferredColorScheme(.dark)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onOpenURL { url in
                    if url.isFileURL {
                        appState.openTrim(
                            files: [url],
                            replacesMainWindow: ExternalLaunch.prefersTrimOnly
                        )
                    } else {
                        appState.acceptExternalURL(url)
                    }
                }
        }
        .handlesExternalEvents(matching: [])
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Framekeep") {
                Button("貼上並下載") {
                    appState.pasteFromClipboard()
                    Task { await appState.continueIngest(source: .clipboard) }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("開始擷取") {
                    appState.selected = .capture
                    Task { await appState.startCapture() }
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("前往下載") { appState.selected = .home }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("前往媒體庫") { appState.selected = .library }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Button("剪接影片…") {
                    appState.trimRequest += 1
                    appState.chooseTrimVideo()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }

        Window("剪接", id: "trim") {
            TrimHost()
                .environmentObject(appState)
                .environmentObject(appState.settings)
                .environmentObject(appState.library)
                .frame(minWidth: 880, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1100, height: 780)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: [])

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(appState.settings)
                .environmentObject(appState.toolchain)
                .frame(minWidth: 560, minHeight: 420)
                .preferredColorScheme(.dark)
        }

        MenuBarExtra("Framekeep", systemImage: "film.stack") {
            Button("貼上並下載") {
                appState.pasteFromClipboard()
                Task { await appState.continueIngest(source: .clipboard) }
            }
            Button("開始擷取") {
                appState.selected = .capture
                Task { await appState.startCapture() }
            }
            Divider()
            Button("顯示 Framekeep") {
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("結束") {
                NSApp.terminate(nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSUpdateDynamicServices()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        let links = urls.filter { !$0.isFileURL }
        if !files.isEmpty {
            TrimFileCenter.shared.receive(files, replacesMainWindow: ExternalLaunch.prefersTrimOnly)
        }
        if !links.isEmpty {
            BrowserLinkCenter.shared.receive(links)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ application: NSApplication) -> Bool {
        true
    }

    @objc func trimFiles(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] ?? []
        let videos = urls.filter(VideoFiles.isVideo)
        guard !videos.isEmpty else {
            error.pointee = "請選擇影片檔。" as NSString
            return
        }
        TrimFileCenter.shared.receive(videos, replacesMainWindow: ExternalLaunch.prefersTrimOnly)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum ExternalLaunch {
    private static let startedAt = Date()

    static var prefersTrimOnly: Bool {
        Date().timeIntervalSince(startedAt) < 3
    }
}

struct TrimFileRequest {
    var urls: [URL]
    var replacesMainWindow: Bool
}

final class TrimFileCenter {
    static let shared = TrimFileCenter()
    private var handler: ((TrimFileRequest) -> Void)?
    private var pending: [TrimFileRequest] = []

    func receive(_ urls: [URL], replacesMainWindow: Bool = false) {
        let request = TrimFileRequest(urls: urls, replacesMainWindow: replacesMainWindow)
        if let handler {
            handler(request)
        } else {
            pending.append(request)
        }
    }

    func bind(_ handler: @escaping (TrimFileRequest) -> Void) {
        self.handler = handler
        let queued = pending
        pending.removeAll()
        for request in queued {
            handler(request)
        }
    }
}

enum TrimWindowFocus {
    static func orderFront(closeMain: Bool) {
        if closeMain {
            setMainWindowHidden(true)
        }
        attempt(30, closeMain: closeMain)
    }

    private static func attempt(_ remaining: Int, closeMain: Bool) {
        DispatchQueue.main.async {
            guard let trim = NSApp.windows.first(where: isTrimWindow) else {
                guard remaining > 0 else {
                    if closeMain { setMainWindowHidden(false) }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    attempt(remaining - 1, closeMain: closeMain)
                }
                return
            }
            closeMainWindows(removeAll: closeMain)
            trim.deminiaturize(nil)
            trim.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            sweepExtraMainWindows(closeMain: closeMain, passes: 4)
        }
    }

    private static func sweepExtraMainWindows(closeMain: Bool, passes: Int) {
        guard passes > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard NSApp.windows.contains(where: isTrimWindow) else {
                sweepExtraMainWindows(closeMain: closeMain, passes: passes - 1)
                return
            }
            closeMainWindows(removeAll: closeMain)
            NSApp.windows.first(where: isTrimWindow)?.makeKeyAndOrderFront(nil)
            sweepExtraMainWindows(closeMain: closeMain, passes: passes - 1)
        }
    }

    private static func closeMainWindows(removeAll: Bool) {
        var mains = NSApp.windows.filter(isFramekeepMain)
        if !removeAll && !ExternalLaunch.prefersTrimOnly {
            mains = Array(mains.dropFirst())
        }
        for window in mains {
            window.close()
        }
    }

    private static func setMainWindowHidden(_ hidden: Bool) {
        for window in NSApp.windows where isFramekeepMain(window) {
            window.alphaValue = hidden ? 0 : 1
        }
    }

    private static func isTrimWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == "framekeep.trim" || window.title == "剪接"
    }

    private static func isFramekeepMain(_ window: NSWindow) -> Bool {
        if window is NSPanel || isTrimWindow(window) { return false }
        if window.identifier?.rawValue == "framekeep.main" { return true }
        return window.title == "Framekeep"
    }
}

struct WindowIdentity: NSViewRepresentable {
    var id: String

    func makeNSView(context: Context) -> NSView {
        let view = IdentityView()
        view.windowID = id
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? IdentityView)?.windowID = id
        nsView.window?.identifier = NSUserInterfaceItemIdentifier(id)
    }
}

private final class IdentityView: NSView {
    var windowID = "" {
        didSet { apply() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    private func apply() {
        guard !windowID.isEmpty else { return }
        window?.identifier = NSUserInterfaceItemIdentifier(windowID)
    }
}

struct TrimHost: View {
    @EnvironmentObject private var app: AppState
    @State private var targeted = false

    var body: some View {
        Group {
            if let item = app.trimTarget {
                TrimSheet(item: item)
                    .id(item.id)
            } else {
                TrimEmptyState()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FKColor.graphite)
        .background(WindowIdentity(id: "framekeep.trim"))
        .onAppear {
            TrimWindowFocus.orderFront(closeMain: app.takeCloseMainAfterTrim())
        }
        .onChange(of: app.trimRequest) { _ in
            TrimWindowFocus.orderFront(closeMain: app.takeCloseMainAfterTrim())
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            app.acceptTrimProviders(providers)
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(FKColor.amber, lineWidth: 2)
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct TrimEmptyState: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 12) {
            Text("剪接")
                .font(FKFont.display(22, weight: .semibold))
                .foregroundStyle(FKColor.paper)
            Text("把影片拖進這個視窗，或選擇一個檔案。")
                .font(FKFont.body(13))
                .foregroundStyle(FKColor.paperMuted)
            AmberButton(title: "選擇影片", action: app.chooseTrimVideo)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

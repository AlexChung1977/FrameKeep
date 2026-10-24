import AppKit
import SwiftUI

@main
struct FramekeepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appState.settings)
                .environmentObject(appState.queue)
                .environmentObject(appState.library)
                .environmentObject(appState.capture)
                .environmentObject(appState.toolchain)
                .frame(minWidth: 920, minHeight: 600)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    appState.acceptExternalURL(url)
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Framekeep") {
                Button("貼上並解析") {
                    appState.pasteFromClipboard()
                    Task { await appState.continueIngest(source: .clipboard) }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("開始擷取") {
                    appState.selected = .capture
                    Task { await appState.startCapture() }
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("前往佇列") { appState.selected = .queue }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("前往媒體庫") { appState.selected = .library }
                    .keyboardShortcut("2", modifiers: [.command, .option])
            }
        }

        Window("剪接", id: "trim") {
            Group {
                if let item = appState.trimTarget {
                    TrimSheet(item: item)
                        .id(item.id)
                }
            }
            .environmentObject(appState)
            .environmentObject(appState.settings)
            .environmentObject(appState.library)
            .frame(minWidth: 880, minHeight: 640)
            .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1100, height: 780)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(appState.settings)
                .environmentObject(appState.toolchain)
                .frame(minWidth: 560, minHeight: 420)
                .preferredColorScheme(.dark)
        }

        MenuBarExtra("Framekeep", systemImage: "film.stack") {
            Button("貼上並解析") {
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
    func application(_ application: NSApplication, open urls: [URL]) {
        BrowserLinkCenter.shared.receive(urls)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ application: NSApplication) -> Bool {
        true
    }
}

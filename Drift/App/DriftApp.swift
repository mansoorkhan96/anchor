import SwiftUI

@main
struct DriftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = DownloadStore.shared

    var body: some Scene {
        Window("Drift", id: "main") {
            MainView()
                .environment(store)
                .frame(minWidth: 860, minHeight: 520)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Download…") { store.addRequest = AddRequest() }
                    .keyboardShortcut("n")
                Button("Add from Clipboard") {
                    let text = NSPasteboard.general.string(forType: .string) ?? ""
                    store.addRequest = AddRequest(url: text)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandMenu("Downloads") {
                Button("Pause All") { store.pauseAll() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Resume All") { store.resumeAll() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

private struct MenuBarLabel: View {
    let store: DownloadStore

    var body: some View {
        if store.activeCount > 0 {
            Text("\(Image(systemName: "arrow.down.circle.fill")) \(Format.speed(store.totalSpeed))")
        } else {
            Image(systemName: "arrow.down.circle")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            _ = DownloadStore.shared
            BrowserBridge.shared.start()
            ClipboardWatcher.shared.start()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            urls.forEach(AppRouter.shared.handle)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            DownloadStore.shared.shutdown()
        }
    }
}

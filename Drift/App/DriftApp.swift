import SwiftUI

@main
struct DriftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = DownloadStore.shared
    @State private var cleanup = CleanupStore.shared

    var body: some Scene {
        Window("Drift", id: "main") {
            MainView()
                .environment(store)
                .environment(cleanup)
                .frame(minWidth: 860, minHeight: 520)
        }
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.hiddenTitleBar)
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
                Divider()
                Picker("Speed", selection: Binding(get: { SpeedMode.current(store.settings) },
                                                   set: { $0.apply(to: store.settings); store.applySpeedLimit() })) {
                    ForEach(SpeedMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("When All Downloads Finish", selection: Binding(get: { store.settings.whenDone },
                                                                      set: { store.settings.whenDone = $0 })) {
                    ForEach(WhenDoneAction.allCases) { Text($0.title).tag($0) }
                }
            }
        }

        MenuBarExtra(isInserted: Binding(get: { store.settings.showMenuBarIcon },
                                         set: { store.settings.showMenuBarIcon = $0 })) {
            MenuBarView()
                .environment(store)
                .environment(cleanup)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
                .environment(cleanup)
        }
    }
}

private struct MenuBarLabel: View {
    let store: DownloadStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if store.activeCount > 0 {
                Text("\(Image(systemName: "arrow.down.circle.fill")) \(Format.speed(store.totalSpeed))")
            } else {
                Image(systemName: "arrow.down.circle")
            }
        }
        .task {
            // The menu bar label lives for the whole session, so it can reopen the main window for the router.
            AppRouter.shared.openMainWindow = { openWindow(id: "main") }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            _ = DownloadStore.shared
            CleanupStore.shared.start()
            BrowserBridge.shared.start()
            ClipboardWatcher.shared.start()
            // Switching to another app (⌘-Tab, Dock, clicking a window) closes the menu bar popover.
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                MainActor.assumeIsolated { AppRouter.shared.closeMenuBarPanel() }
            }
            // Escape closes the menu bar popover.
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53, let window = event.window,
                      String(describing: type(of: window)).contains("MenuBarExtra") else { return event }
                AppRouter.shared.closeMenuBarPanel()
                return nil
            }
            #if DEBUG
            DebugSnapshot.install()
            #endif
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

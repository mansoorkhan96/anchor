import SwiftUI

@main
struct AnchorApp: App {
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
            MenuBarLabel(store: store, cleanup: cleanup)
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
    let cleanup: CleanupStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // A dot on the icon once at least 1 GB is ready for cleanup.
        let dot = cleanup.attentionBytes >= 1_000_000_000
        Group {
            if store.activeCount > 0 {
                Text("\(Image(nsImage: MenuBarIcon.image(filled: true, dot: dot))) \(Format.speed(store.totalSpeed))")
            } else {
                Image(nsImage: MenuBarIcon.image(filled: false, dot: dot))
            }
        }
        .task {
            // The menu bar label lives for the whole session, so it can reopen the main window for the router.
            AppRouter.shared.openMainWindow = { openWindow(id: "main") }
        }
    }
}

/// The status item glyph: the real app icon, optionally with a small red dot in its top-right corner.
/// Not a template image, so it keeps its colors in light and dark menu bars.
@MainActor
private enum MenuBarIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(filled: Bool, dot: Bool) -> NSImage {
        let key = "\(dot)"
        if let cached = cache[key] { return cached }
        let icon = appIcon()
        let image = dot ? dotted(icon) : icon
        cache[key] = image
        return image
    }

    /// The app icon at menu bar size. The icon's tile fills about 80% of its canvas (the rest is the shadow
    /// margin), so it is drawn larger and cropped to let the tile itself fill the 16 pt glyph.
    private static func appIcon() -> NSImage {
        let source = NSApp.applicationIconImage ?? NSImage()
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let side = rect.width * 1024 / 824
            let inset = (side - rect.width) / 2
            source.draw(in: NSRect(x: -inset, y: -inset, width: side, height: side))
            return true
        }
        image.accessibilityDescription = "Drift"
        return image
    }

    private static func dotted(_ symbol: NSImage) -> NSImage {
        let size = NSSize(width: symbol.size.width + 2, height: symbol.size.height)
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return symbol }
        // Points, not pixels: the size must be set before the context is made.
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return symbol }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
        let diameter: CGFloat = 6
        let dot = NSRect(x: size.width - diameter, y: size.height - diameter, width: diameter, height: diameter)
        // Clear a ring around the dot so it reads as a badge, not part of the circle.
        context.compositingOperation = .clear
        NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
        context.compositingOperation = .sourceOver
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: dot).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            _ = DownloadStore.shared
            CleanupStore.shared.start()
            BrowserBridge.shared.start()
            NativeHost.register()
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

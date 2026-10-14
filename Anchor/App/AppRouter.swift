import AppKit

/// Routes external input (URL schemes, opened files, the browser bridge) into the store and UI.
@MainActor
final class AppRouter {
    static let shared = AppRouter()

    private var store: DownloadStore { .shared }
    var openMainWindow: (() -> Void)?

    func handle(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "magnet":
            present(AddRequest(url: url.absoluteString))
        case "file" where url.pathExtension.lowercased() == "torrent":
            present(AddRequest(url: url.absoluteString))
        case "anchor":
            let link = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "url" }?.value
            if let link { present(AddRequest(url: link)) }
        default:
            break
        }
    }

    func handleBrowserDownload(url: String, fileName: String?, headers: [String: String], cookieJar: [BrowserCookie] = []) {
        // Video links always open the window: they need a quality, and adding one directly would save the page.
        let video = URL(string: url).map(MediaLinkDetector.isLikelyMedia) ?? false
        if AppSettings.shared.confirmBrowserDownloads || video {
            present(AddRequest(url: url, headers: headers, cookieJar: cookieJar, suggestedName: fileName, fromBrowser: true))
        } else {
            store.add(url, fileName: fileName, headers: headers)
        }
    }

    /// Inside Anchor: a sheet on the main window. From another app (e.g. the browser): a floating panel,
    /// because macOS won't let a background app pull itself to the front.
    /// Brings up the main window with this download's details open.
    func showDetails(_ id: UUID) {
        store.focusedID = id
        activate()
    }

    /// Brings up the main window on the Cleanup list.
    func showCleanup() {
        store.pendingFilter = .cleanup
        activate()
    }

    func present(_ request: AddRequest) {
        if NSApp.isActive {
            store.addRequest = request
            openMainWindow?()
        } else {
            AddDownloadPanel.shared.show(request)
        }
    }

    func activate() {
        openMainWindow?()
        NSApp.activate()
        closeMenuBarPanel()
    }

    /// Dismisses the menu bar popover (SwiftUI's MenuBarExtra window) once the main window takes over.
    /// Toggles it through the status bar button (rather than closing its window) so the button's state stays in sync.
    func closeMenuBarPanel() {
        let panelOpen = NSApp.windows.contains {
            String(describing: type(of: $0)).contains("MenuBarExtra") && $0.isVisible
        }
        guard panelOpen else { return }
        for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBarWindow") {
            if let button = Self.statusButton(in: window.contentView) {
                button.performClick(nil)
                return
            }
        }
    }

    private static func statusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews { if let found = statusButton(in: sub) { return found } }
        return nil
    }
}

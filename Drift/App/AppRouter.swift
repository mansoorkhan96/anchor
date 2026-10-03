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
        case "drift":
            // drift://add?url=<encoded>
            let link = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "url" }?.value
            if let link { present(AddRequest(url: link)) }
        default:
            break
        }
    }

    func handleBrowserDownload(url: String, fileName: String?, headers: [String: String]) {
        if AppSettings.shared.confirmBrowserDownloads {
            present(AddRequest(url: url, headers: headers, suggestedName: fileName, fromBrowser: true))
        } else {
            store.add(url, fileName: fileName, headers: headers)
        }
    }

    /// Inside Drift: a sheet on the main window. From another app (e.g. the browser): a floating panel,
    /// because macOS won't let a background app pull itself to the front.
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
    }
}

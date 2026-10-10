import AppKit

/// Polls the pasteboard for download links and magnets and offers them in the UI.
@MainActor
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()

    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardWatcher.shared.check() }
        }
    }

    private func check() {
        let board = NSPasteboard.general
        guard board.changeCount != lastChange else { return }
        lastChange = board.changeCount
        guard AppSettings.shared.clipboardMonitoring,
              let text = board.string(forType: .string),
              let url = Self.downloadLink(in: text) else { return }
        let store = DownloadStore.shared
        guard !store.items.contains(where: { $0.url == url }) else { return }
        store.clipboardSuggestion = url
    }

    /// The URL in `text` if it is a magnet or an http(s) link to a file with a downloadable extension.
    nonisolated static func downloadLink(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isNewline), trimmed.count < 4096,
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "magnet" { return trimmed.contains("xt=urn:btih:") ? url : nil }
        guard scheme == "http" || scheme == "https", url.host() != nil else { return nil }
        return FileCategory.downloadableExtensions.contains(url.pathExtension.lowercased()) ? url : nil
    }
}

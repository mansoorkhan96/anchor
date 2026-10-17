import AppIntents
import Foundation

/// Shortcuts actions. They run inside Anchor (launching it in the background if needed), so they act on the same
/// store as the window and the menu bar.

struct AddDownloadIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Download"
    static let description = IntentDescription("""
        Downloads a link with Anchor: a file, a magnet link or a torrent. Video links open the New Download window so \
        you can pick a quality.
        """)

    @Parameter(title: "Link", description: "An http(s) link, a magnet link, or a link to a .torrent file.")
    var link: URL

    @Parameter(title: "Review First", description: "Open the New Download window instead of starting right away.",
               default: false)
    var review: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Download \(\.$link)") { \.$review }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let scheme = link.scheme?.lowercased() ?? ""
        guard ["http", "https", "magnet"].contains(scheme) else { throw AnchorIntentError.unsupportedLink }
        // Video links need a quality, and adding one directly would save the web page.
        if review || MediaLinkDetector.isLikelyMedia(link) {
            AppRouter.shared.present(AddRequest(url: link.absoluteString))
        } else {
            DownloadStore.shared.add(link.absoluteString)
        }
        return .result()
    }
}

struct PauseAllIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause All Downloads"
    static let description = IntentDescription("Pauses every download that is running or waiting in Anchor.")

    @MainActor
    func perform() async throws -> some IntentResult {
        DownloadStore.shared.pauseAll()
        return .result()
    }
}

struct ResumeAllIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume All Downloads"
    static let description = IntentDescription("Resumes paused and failed downloads in Anchor.")

    @MainActor
    func perform() async throws -> some IntentResult {
        DownloadStore.shared.resumeAll()
        return .result()
    }
}

struct DownloadStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Download Status"
    static let description = IntentDescription("Says how many downloads are running and waiting, and the total speed.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = DownloadStatusIntent.summary(active: DownloadStore.shared.activeCount,
                                                queued: DownloadStore.shared.queuedCount,
                                                speed: DownloadStore.shared.totalSpeed)
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }

    /// "2 downloading at 5.2 MB/s, 3 waiting", or "Nothing is downloading".
    static func summary(active: Int, queued: Int, speed: Double) -> String {
        var parts: [String] = []
        if active > 0 { parts.append("\(active) downloading at \(Format.speed(speed))") }
        if queued > 0 { parts.append("\(queued) waiting") }
        return parts.isEmpty ? "Nothing is downloading" : parts.joined(separator: ", ")
    }
}

enum AnchorIntentError: Error, CustomLocalizedStringResourceConvertible {
    case unsupportedLink

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unsupportedLink: "Anchor can download http(s) links, magnet links and links to .torrent files."
        }
    }
}

/// Ready-made actions in the Shortcuts app and Spotlight, with Siri phrases.
struct AnchorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddDownloadIntent(), phrases: ["Download with \(.applicationName)", "Add a download to \(.applicationName)"],
                    shortTitle: "Add Download", systemImageName: "arrow.down.circle")
        AppShortcut(intent: PauseAllIntent(), phrases: ["Pause downloads in \(.applicationName)", "Pause \(.applicationName)"],
                    shortTitle: "Pause All", systemImageName: "pause.circle")
        AppShortcut(intent: ResumeAllIntent(), phrases: ["Resume downloads in \(.applicationName)", "Resume \(.applicationName)"],
                    shortTitle: "Resume All", systemImageName: "play.circle")
        AppShortcut(intent: DownloadStatusIntent(), phrases: ["How are my \(.applicationName) downloads", "\(.applicationName) status"],
                    shortTitle: "Download Status", systemImageName: "gauge.with.dots.needle.67percent")
    }
}

import SwiftUI

/// The New Download window's card for a video link: thumbnail, editable title and what yt-dlp found,
/// or the state of the video tools while they are missing.
struct MediaCard: View {
    @Binding var fileName: String
    let result: MediaProbeResult?
    let probing: Bool
    let quality: MediaQuality
    private var tools: ToolManager { .shared }

    var body: some View {
        HStack(spacing: 14) {
            thumbnail
            VStack(alignment: .leading, spacing: 8) {
                TextField("Title", text: $fileName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.anchorText)
                    .disabled(result == nil)
                HStack(spacing: 6) { chips }
                    .frame(height: 20)
            }
        }
        .padding(14)
        .background(Color.anchorCard, in: .rect(cornerRadius: 14))
    }

    @ViewBuilder private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        Group {
            if let url = result?.thumbnail {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.anchorField
                }
            } else {
                Image(systemName: quality.isAudio ? "music.note" : "film")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(quality.category.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.anchorField)
            }
        }
        .frame(width: 82, height: 46)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.anchorLine))
    }

    @ViewBuilder private var chips: some View {
        if !tools.isReady {
            if tools.isInstalling || !tools.refreshed {
                ProgressView().controlSize(.mini)
                Text(tools.isInstalling ? "Installing video tools…" : "Checking video tools…")
                    .font(.system(size: 11)).foregroundStyle(Color.anchorMuted)
            } else {
                Chip(text: "Video tools needed", ink: .anchorAccentInk, wash: .anchorAccentWash)
                Button("Install all") { tools.installAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.anchorAccentInk)
            }
        } else if probing {
            ProgressView().controlSize(.mini)
            Text("Checking video…").font(.system(size: 11)).foregroundStyle(Color.anchorMuted)
        } else if let result {
            if let site = result.extractorKey ?? result.extractor {
                Chip(text: site, ink: .anchorSuccess, wash: .anchorSuccessWash)
            }
            if let duration = result.duration, duration > 0 {
                Chip(text: Self.clock(duration), ink: .anchorText.opacity(0.8))
            }
            if let uploader = result.uploader, !uploader.isEmpty {
                Chip(text: uploader, ink: .anchorText.opacity(0.8))
            }
            if let size = result.estimatedSize(quality) {
                Chip(text: "About \(Format.bytes(size))", ink: .anchorText.opacity(0.8))
            }
        }
    }

    /// 19 s is "0:19", 3725 s is "1:02:05".
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Why a video couldn't be downloaded, in plain words, with yt-dlp's own text behind Details and, when signing in
/// would help, a choice of browser to take cookies from.
struct MediaErrorNote: View {
    /// yt-dlp's message (or the plain one when there is no raw text).
    let raw: String
    var plain: String? = nil
    /// When the last attempt failed (downloads only).
    var failedAt: Date? = nil
    /// Called after a browser is picked (the window probes again, a download retries).
    var onCookiesChanged: () -> Void = {}
    @State private var showDetails = false

    var body: some View {
        let kind = MediaErrors.kind(of: raw)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.anchorDanger)
                Text(plain ?? MediaErrors.friendly(raw))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.anchorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failedAt {
                Text("Last tried at \(failedAt.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.anchorMuted)
            }
            if kind.wantsCookies {
                CookieBrowserMenu(onChange: onCookiesChanged)
            }
            if MediaErrors.friendly(raw) != raw {
                Button(showDetails ? "Hide details" : "Details") { showDetails.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.anchorMuted)
                if showDetails {
                    Text(raw)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.anchorMuted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.anchorDangerWash, in: .rect(cornerRadius: 12))
    }
}

/// Picks the browser whose cookies yt-dlp uses, so sites see a signed-in user. Only installed browsers are listed.
struct CookieBrowserMenu: View {
    var onChange: () -> Void = {}
    private var settings: AppSettings { .shared }

    var body: some View {
        let installed = MediaCookies.browsers.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
        let current = settings.mediaCookieBrowser
        VStack(alignment: .leading, spacing: 4) {
            Menu {
                ForEach(installed, id: \.name) { browser in
                    Button {
                        pick(browser.name)
                    } label: {
                        let title = browser.name == "safari" ? "Safari (needs Full Disk Access for Anchor)" : browser.title
                        if browser.name == current { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
                if !current.isEmpty {
                    Divider()
                    Button("Don't Use Browser Cookies") { pick("") }
                }
            } label: {
                Text(current.isEmpty ? "Use cookies from your browser…" : "Using cookies from \(MediaCookies.title(ofBrowser: current))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.anchorAccentInk)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            Text("Sign in to the site in that browser. macOS may ask once to let Anchor read its cookies.")
                .font(.system(size: 11))
                .foregroundStyle(Color.anchorMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pick(_ name: String) {
        settings.mediaCookieBrowser = name
        onChange()
    }
}

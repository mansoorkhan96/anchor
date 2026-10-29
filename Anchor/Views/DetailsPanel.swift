import SwiftUI

/// Slide-over from the right with a download's details: files for torrents, plus general info.
struct DetailsPanel: View {
    @Environment(DownloadStore.self) private var store
    let item: DownloadItem
    @Binding var width: CGFloat
    let close: () -> Void

    enum Tab: String, CaseIterable { case files = "Files", general = "General" }
    @State private var tab: Tab = .files
    @State private var dragStart: CGFloat?
    @State private var escapeMonitor: Any?

    private var tabs: [Tab] { item.files == nil ? [.general] : Tab.allCases }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                FileTile(item: item, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.fileName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.anchorText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(kindLine)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.anchorMuted)
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    if let kind = DownloadStore.startOverKind(item) {
                        let again = kind == .downloadAgain
                        IconButton(symbol: "arrow.clockwise",
                                   label: again ? "Download Again" : "Start Over", tint: .anchorText, fill: .anchorField,
                                   size: 28, outlined: true, glyphScale: 0.34) { store.startOver(item.id) }
                            .help(again ? "Download a fresh copy as a new download"
                                        : "Start Over: discard what was downloaded and start from the beginning")
                    }
                    StatusAction(item: item)
                    IconButton(symbol: "xmark", label: "Close details", tint: .anchorMuted2, fill: .anchorField, size: 28,
                               outlined: true, action: close)
                }
            }

            if tabs.count > 1 {
                AnchorSegmented(options: tabs, selection: $tab, title: \.rawValue, minWidth: 0,
                               symbol: { $0 == .files ? "doc.on.doc" : "info.circle" })
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Group {
                if tabs.contains(.files), tab == .files, let files = item.files {
                    TorrentFileList(files: files, showProgress: true, maxHeight: .infinity, compact: true,
                                    rootFolder: item.fileName,
                                    onInclude: { store.setFile($0, of: item.id, included: $1) },
                                    onPriority: { store.setFilePriority($0, of: item.id, to: $1) },
                                    onAll: { store.setAllFiles(of: item.id, included: $0) })
                } else {
                    GeneralDetails(item: item)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(18)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.anchorWindow)
        .overlay(alignment: .leading) {
            // Resize handle on the left edge
            Rectangle()
                .fill(Color.anchorLine)
                .frame(width: 1)
                .frame(width: 8)
                .contentShape(.rect)
                .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let start = dragStart ?? width
                            dragStart = start
                            width = min(640, max(360, start - value.translation.width))
                        }
                        .onEnded { _ in dragStart = nil }
                )
                .offset(x: -4)
        }
        .shadow(color: .black.opacity(0.08), radius: 16, x: -6)
        .onChange(of: item.id) { tab = item.files == nil ? .general : .files }
        .onAppear {
            tab = item.files == nil ? .general : .files
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Escape in the main window (not a sheet or the floating New Download panel) closes the slide-over.
                guard event.keyCode == 53, let window = event.window, window.title == "Anchor",
                      window.attachedSheet == nil else { return event }
                close()
                return nil
            }
        }
        .onDisappear {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            escapeMonitor = nil
        }
    }

    private var kindLine: String {
        if let files = item.files { return "Torrent · \(files.count) file\(files.count == 1 ? "" : "s")" }
        if item.kind == .torrent { return "Torrent" }
        if item.kind == .media {
            let kind = item.mediaQuality?.isAudio == true ? "Audio" : "Video"
            return [kind, item.mediaInfo?.extractor ?? item.url.host()].compactMap { $0 }.joined(separator: " · ")
        }
        return item.url.host() ?? item.category.title
    }
}

/// Round toggle next to the close button: resume, pause, retry, or show in Finder.
private struct StatusAction: View {
    @Environment(DownloadStore.self) private var store
    let item: DownloadItem

    var body: some View {
        switch item.state {
        case .downloading, .connecting, .queued:
            IconButton(symbol: "pause.fill", label: "Pause", tint: .anchorText, fill: .anchorField, size: 28, outlined: true, glyphScale: 0.32) { store.pause(item.id) }
        case .paused:
            IconButton(symbol: "play.fill", label: "Resume", tint: .white, fill: .anchorAccentStrong, size: 28, glyphScale: 0.32) { store.resume(item.id) }
        case .failed:
            IconButton(symbol: "play.fill", label: "Retry", tint: .white, fill: .anchorAccentStrong, size: 28, glyphScale: 0.32) { store.retry(item.id) }
        case .completed:
            RevealButton(size: 28, outlined: true) { store.reveal(item.id) }
        }
    }
}

private struct GeneralDetails: View {
    @Environment(DownloadStore.self) private var store
    let item: DownloadItem

    var body: some View {
        ScrollView {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 10) {
                row("Status") {
                    HStack(spacing: 12) {
                        // StatusPill draws nothing while downloading, so the live detail stands on its own.
                        if item.state == .downloading {
                            Text(item.mediaPhase?.detail ?? "Downloading · \(Format.speed(item.speed))").font(.system(size: 12.5)).foregroundStyle(Color.anchorText)
                        } else {
                            StatusPill(state: item.state, compact: true)
                        }
                        if let kind = DownloadStore.startOverKind(item) {
                            Button(kind == .downloadAgain ? "Download Again" : "Start Over") { store.startOver(item.id) }
                                .buttonStyle(.plain)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Color.anchorAccentInk)
                                .help(kind == .downloadAgain ? "Download a fresh copy as a new download"
                                                             : "Discard what was downloaded and start from the beginning")
                        }
                    }
                }
                if case .failed(let message) = item.state {
                    row("Error") {
                        if item.kind == .media {
                            MediaErrorNote(raw: item.mediaError ?? message, plain: message, failedAt: item.failedAt)
                        } else {
                            Text(message)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color.anchorDanger)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                row("Address") {
                    Text(item.url.absoluteString)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.anchorText)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                row("Saved to") {
                    HStack(spacing: 8) {
                        Text(displayPath(item.directory.appending(path: item.fileName)))
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.anchorText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Show in Finder") { store.reveal(item.id) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.anchorAccentInk)
                    }
                }
                row("Size") { value(Format.progress(item.receivedBytes, of: item.totalBytes)) }
                row("Added") { value(item.createdAt.formatted(date: .abbreviated, time: .shortened)) }
                if let done = item.completedAt {
                    row("Finished") { value(done.formatted(date: .abbreviated, time: .shortened)) }
                }
                if item.kind == .media {
                    if let quality = item.mediaQuality { row("Quality") { value(quality.title + (item.mediaConvertHeight != nil ? " (Convert to MP4)" : "")) } }
                    if let title = item.mediaInfo?.title { row("Title") { value(title) } }
                } else {
                    row(item.kind == .torrent ? "Peers" : "Connections") { value("\(item.connections)") }
                }
                if item.kind == .http {
                    row("Resumable") { value(item.supportsRanges ? "Yes" : "No") }
                }
                row("Priority") {
                    PriorityMenu(priority: item.priority ?? .normal) { store.setPriority([item.id], to: $0) }
                }
                if item.state.isFinished {
                    row("Keep") {
                        HStack(spacing: 8) {
                            AnchorSwitch(isOn: Binding(get: { item.keep == true }, set: { store.setKeep([item.id], $0) }), label: "Keep")
                                .disabled(item.pendingMove != nil)
                                .opacity(item.pendingMove != nil ? 0.45 : 1)
                            Text(item.pendingMove != nil ? "Waiting to finish moving" : "Never suggest for cleanup or archive")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.anchorMuted)
                        }
                    }
                }
                if let archived = archivedLine(item) {
                    row("Archive") { value(archived) }
                }
                if !item.state.isFinished {
                    row("Speed limit") {
                        Menu {
                            SpeedLimitMenuItems(current: item.speedLimitKB) { store.setSpeedLimit([item.id], kb: $0) }
                        } label: {
                            HStack(spacing: 6) {
                                Text(item.speedLimitKB.map { Format.speed(Double($0 * 1000)) } ?? "No limit")
                                    .font(.system(size: 12.5).monospacedDigit())
                                MenuChevron().font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundStyle(item.speedLimitKB == nil ? Color.anchorText : Color.anchorPausedInk)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(Color.anchorField, in: .rect(cornerRadius: 7))
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(Color.anchorCard, in: .rect(cornerRadius: 12))
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Color.anchorMuted)
                .gridColumnAlignment(.trailing)
            content()
        }
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5).monospacedDigit())
            .foregroundStyle(Color.anchorText)
    }

    private func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

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
                        .foregroundStyle(Color.driftText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(kindLine)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.driftMuted)
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    StatusAction(item: item)
                    IconButton(symbol: "xmark", label: "Close details", tint: .driftMuted2, fill: .driftField, size: 28,
                               outlined: true, action: close)
                }
            }

            if tabs.count > 1 {
                DriftSegmented(options: tabs, selection: $tab, title: \.rawValue, minWidth: 0,
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
        .background(Color.driftWindow)
        .overlay(alignment: .leading) {
            // Resize handle on the left edge
            Rectangle()
                .fill(Color.driftLine)
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
                guard event.keyCode == 53, let window = event.window, window.title == "Drift",
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
            IconButton(symbol: "pause.fill", label: "Pause", tint: .driftText, fill: .driftField, size: 28, outlined: true, glyphScale: 0.32) { store.pause(item.id) }
        case .paused:
            IconButton(symbol: "play.fill", label: "Resume", tint: .white, fill: .driftAccentStrong, size: 28, glyphScale: 0.32) { store.resume(item.id) }
        case .failed:
            IconButton(symbol: "arrow.clockwise", label: "Retry", tint: .white, fill: .driftAccentStrong, size: 28, glyphScale: 0.34) { store.retry(item.id) }
        case .completed:
            IconButton(symbol: "magnifyingglass", label: "Show in Finder", tint: .driftText, fill: .driftField, size: 28, outlined: true) { store.reveal(item.id) }
        }
    }
}

private struct GeneralDetails: View {
    @Environment(DownloadStore.self) private var store
    let item: DownloadItem

    var body: some View {
        ScrollView {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 10) {
                row("Status") { StatusPill(state: item.state, compact: true).opacity(item.state == .downloading ? 0 : 1)
                    .overlay(alignment: .leading) {
                        if item.state == .downloading {
                            Text("Downloading · \(Format.speed(item.speed))").font(.system(size: 12.5)).foregroundStyle(Color.driftText)
                        }
                    }
                }
                row("Address") {
                    Text(item.url.absoluteString)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.driftText)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                row("Saved to") {
                    HStack(spacing: 8) {
                        Text(displayPath(item.directory.appending(path: item.fileName)))
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.driftText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Show in Finder") { store.reveal(item.id) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.driftAccentInk)
                    }
                }
                row("Size") { value(Format.progress(item.receivedBytes, of: item.totalBytes)) }
                row("Added") { value(item.createdAt.formatted(date: .abbreviated, time: .shortened)) }
                if let done = item.completedAt {
                    row("Finished") { value(done.formatted(date: .abbreviated, time: .shortened)) }
                }
                row(item.kind == .torrent ? "Peers" : "Connections") { value("\(item.connections)") }
                if item.kind == .http {
                    row("Resumable") { value(item.supportsRanges ? "Yes" : "No") }
                }
                row("Priority") {
                    PriorityMenu(priority: item.priority ?? .normal) { store.setPriority([item.id], to: $0) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(Color.driftCard, in: .rect(cornerRadius: 12))
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Color.driftMuted)
                .gridColumnAlignment(.trailing)
            content()
        }
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5).monospacedDigit())
            .foregroundStyle(Color.driftText)
    }

    private func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

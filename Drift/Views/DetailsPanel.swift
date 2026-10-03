import SwiftUI

/// Drag-up panel under the download list (like FDM's): files for torrents, plus general details.
struct DetailsPanel: View {
    @Environment(DownloadStore.self) private var store
    let item: DownloadItem
    @Binding var height: CGFloat
    let close: () -> Void

    enum Tab: String, CaseIterable { case files = "Files", general = "General" }
    @State private var tab: Tab = .files
    @State private var dragStart: CGFloat?

    private var tabs: [Tab] { item.files == nil ? [.general] : Tab.allCases }

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color.driftTrack)
                .frame(width: 38, height: 5)
                .frame(maxWidth: .infinity)
                .frame(height: 14)
                .contentShape(.rect)
                .onHover { inside in
                    if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let start = dragStart ?? height
                            dragStart = start
                            height = min(560, max(170, start - value.translation.height))
                        }
                        .onEnded { _ in dragStart = nil }
                )

            HStack(spacing: 12) {
                FileTile(item: item, size: 30)
                Text(item.fileName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.driftText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                if tabs.count > 1 {
                    DriftSegmented(options: tabs, selection: $tab, title: \.rawValue, minWidth: 64, symbol: { $0 == .files ? "doc.on.doc" : "info.circle" })
                }
                IconButton(symbol: "xmark", label: "Close details", tint: .driftMuted2, fill: .clear, size: 28, action: close)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            Group {
                if tabs.contains(.files), tab == .files, let files = item.files {
                    TorrentFileList(files: files, showProgress: true, maxHeight: .infinity,
                                    onInclude: { store.setFile($0, of: item.id, included: $1) },
                                    onPriority: { store.setFilePriority($0, of: item.id, to: $1) },
                                    onAll: { store.setAllFiles(of: item.id, included: $0) })
                } else {
                    GeneralDetails(item: item)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(height: height)
        .background(Color.driftWindow)
        .overlay(alignment: .top) { Rectangle().fill(Color.driftLine).frame(height: 1) }
        .shadow(color: .black.opacity(0.06), radius: 10, y: -4)
        .onChange(of: item.id) { tab = item.files == nil ? .general : .files }
        .onAppear { tab = item.files == nil ? .general : .files }
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

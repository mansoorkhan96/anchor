import SwiftUI
import Charts

struct DownloadListView: View {
    @Environment(DownloadStore.self) private var store
    let filter: SidebarFilter

    @State private var search = ""
    @State private var selection: Set<UUID> = []
    @State private var confirmDelete = false

    private var visible: [DownloadItem] { store.items(for: filter, search: search) }

    var body: some View {
        @Bindable var settings = store.settings
        let items = visible

        ScrollView {
            VStack(spacing: 14) {
                if let link = store.clipboardSuggestion {
                    ClipboardBanner(url: link)
                }
                if store.activeCount > 0 || store.totalSpeed > 0 {
                    ThroughputCard()
                }
                if items.isEmpty {
                    EmptyState(filter: filter, searching: !search.isEmpty)
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(items) { item in
                            DownloadRow(item: item, isSelected: selectionBinding(item.id))
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, selection.isEmpty ? 20 : 84)
            .animation(.snappy(duration: 0.25), value: items.map(\.id))
            .animation(.snappy(duration: 0.25), value: store.clipboardSuggestion)
        }
        .overlay(alignment: .bottom) {
            if !selection.isEmpty {
                SelectionBar(count: selection.count,
                             allSelected: selection.count == items.count,
                             selectAll: { selection = Set(items.map(\.id)) },
                             clear: { selection.removeAll() },
                             move: moveSelection,
                             delete: { confirmDelete = true })
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: selection.isEmpty)
        .navigationTitle(filter.title)
        .navigationSubtitle(subtitle)
        .searchable(text: $search, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Picker("Sort By", selection: $settings.sortOrder) {
                        ForEach(SortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort downloads")

                Button {
                    store.activeCount + store.queuedCount > 0 ? store.pauseAll() : store.resumeAll()
                } label: {
                    Label(store.activeCount + store.queuedCount > 0 ? "Pause All" : "Resume All",
                          systemImage: store.activeCount + store.queuedCount > 0 ? "pause.fill" : "play.fill")
                }
                .help(store.activeCount + store.queuedCount > 0 ? "Pause all downloads" : "Resume all downloads")
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button {
                    store.addRequest = AddRequest()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
                .help("New download (⌘N)")
            }
        }
        .onChange(of: filter) { selection.removeAll() }
        .onChange(of: store.items.map(\.id)) { _, ids in
            selection.formIntersection(ids)
        }
        .confirmationDialog("Delete \(selection.count) download\(selection.count == 1 ? "" : "s")?",
                            isPresented: $confirmDelete) {
            Button("Move Files to Trash", role: .destructive) {
                store.remove(selection, deleteFiles: true)
                selection.removeAll()
            }
            Button("Remove from List Only") {
                store.remove(selection, deleteFiles: false)
                selection.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unfinished downloads are stopped. Removing from the list keeps finished files on disk.")
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if store.activeCount > 0 { parts.append("\(store.activeCount) active") }
        if store.queuedCount > 0 { parts.append("\(store.queuedCount) queued") }
        return parts.joined(separator: " · ")
    }

    private func selectionBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { selection.contains(id) },
            set: { if $0 { selection.insert(id) } else { selection.remove(id) } }
        )
    }

    private func moveSelection() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.message = "Choose a folder for \(selection.count) download\(selection.count == 1 ? "" : "s")"
        panel.directoryURL = store.settings.downloadFolder
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        store.move(selection, to: folder)
        selection.removeAll()
    }
}

// MARK: - Throughput

struct ThroughputCard: View {
    @Environment(DownloadStore.self) private var store

    var body: some View {
        let parts = Format.speedParts(store.totalSpeed)
        let remaining = store.remainingBytes
        HStack(alignment: .bottom, spacing: 28) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Total speed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(parts.value)
                        .font(.system(size: 44, weight: .light, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text(parts.unit)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 150, alignment: .leading)

            Chart(Array(store.speedHistory.enumerated()), id: \.offset) { point in
                AreaMark(x: .value("t", point.offset), y: .value("speed", point.element))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.driftAccent.opacity(0.14))
                LineMark(x: .value("t", point.offset), y: .value("speed", point.element))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.driftAccent)
                    .lineStyle(StrokeStyle(lineWidth: 1.75))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...max(1, (store.speedHistory.max() ?? 1) * 1.15))
            .frame(height: 64)

            HStack(spacing: 24) {
                stat("Remaining", Format.bytes(remaining))
                stat("Done in", store.totalSpeed > 1 ? Format.duration(Double(remaining) / store.totalSpeed) : "-")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.06)))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .monospaced))
                .contentTransition(.numericText())
        }
    }
}

// MARK: - Selection

private struct SelectionBar: View {
    let count: Int
    let allSelected: Bool
    let selectAll: () -> Void
    let clear: () -> Void
    let move: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("\(count) selected")
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .padding(.leading, 14)
                .padding(.trailing, 6)
            if !allSelected {
                Button("Select All", action: selectAll)
                    .buttonStyle(.borderless)
            }
            Divider().frame(height: 18).padding(.horizontal, 4)
            Button(action: move) {
                Image(systemName: "folder")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help("Move to folder…")
            .accessibilityLabel("Move to folder")
            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("Delete")
            .accessibilityLabel("Delete")
            Button(action: clear) {
                Image(systemName: "xmark")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .help("Clear selection")
            .accessibilityLabel("Clear selection")
        }
        .padding(6)
        .glassEffect(.regular, in: .capsule)
    }
}

// MARK: - Clipboard banner

private struct ClipboardBanner: View {
    @Environment(DownloadStore.self) private var store
    let url: URL

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(Color.driftAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Download link on your clipboard")
                    .font(.callout.weight(.medium))
                Text(url.scheme == "magnet" ? "Magnet link" : url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Dismiss") { store.clipboardSuggestion = nil }
                .buttonStyle(.borderless)
            Button("Add") {
                store.addRequest = AddRequest(url: url.absoluteString)
                store.clipboardSuggestion = nil
            }
            .buttonStyle(.glassProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

private struct EmptyState: View {
    let filter: SidebarFilter
    let searching: Bool

    var body: some View {
        ContentUnavailableView {
            Label(searching ? "No Results" : "Nothing Here", systemImage: searching ? "magnifyingglass" : "arrow.down.circle.dotted")
        } description: {
            Text(searching ? "No downloads match your search." : "Paste a link with ⌘⇧V, drop a URL or .torrent here, or download from your browser.")
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

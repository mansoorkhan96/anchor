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
                    LazyVStack(spacing: 8) {
                        ForEach(items) { item in
                            DownloadRow(item: item, isSelected: selectionBinding(item.id))
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 84)
            .animation(.snappy(duration: 0.25), value: items.map(\.id))
            .animation(.snappy(duration: 0.25), value: store.clipboardSuggestion)
        }
        .overlay(alignment: .bottom) {
            ZStack {
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
            .animation(.snappy(duration: 0.22), value: selection.isEmpty)
        }
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
                    Label("Sort", systemImage: "line.3.horizontal.decrease")
                }
                .menuIndicator(.hidden)
                .help("Sort downloads")

                Button {
                    anyRunning ? store.pauseAll() : store.resumeAll()
                } label: {
                    Label(anyRunning ? "Pause All" : "Resume All", systemImage: anyRunning ? "pause" : "play")
                }
                .help(anyRunning ? "Pause all downloads" : "Resume all downloads")
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button {
                    store.addRequest = AddRequest()
                } label: {
                    Label("New Download", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.glassProminent)
                .tint(.driftAccentStrong)
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

    private var anyRunning: Bool { store.activeCount + store.queuedCount > 0 }

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
        let history = Array(store.speedHistory.enumerated())
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Total speed")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.driftMuted2)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(parts.value)
                        .font(.system(size: 50, weight: .heavy).monospacedDigit())
                        .tracking(-1.2)
                        .foregroundStyle(Color.driftText)
                        .contentTransition(.numericText())
                    Text(parts.unit)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.driftMuted2)
                }
                Chip(text: pace.text, ink: pace.ink, wash: pace.wash)
                    .padding(.top, 4)
            }
            .frame(minWidth: 180, alignment: .leading)

            Chart(history, id: \.offset) { point in
                AreaMark(x: .value("t", point.offset), y: .value("speed", point.element))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [Color.driftAccent.opacity(0.22), Color.driftAccent.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("t", point.offset), y: .value("speed", point.element))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.driftAccent)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...max(1, (store.speedHistory.max() ?? 1) * 1.15))
            .frame(height: 72)

            HStack(spacing: 24) {
                stat("Remaining", Format.bytes(remaining))
                stat("Done in", store.totalSpeed > 1 ? Format.duration(Double(remaining) / store.totalSpeed) : "-")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(Color.driftCard, in: .rect(cornerRadius: 18))
    }

    private var pace: (text: String, ink: Color, wash: Color) {
        let active = "\(store.activeCount) active"
        switch store.totalSpeed {
        case 5_000_000...: return ("Fast · \(active)", .driftSuccess, .driftSuccessWash)
        case 500_000...: return ("Steady · \(active)", .driftAccentInk, .driftAccentWash)
        default: return ("Slow · \(active)", .driftPausedInk, Color.driftPaused.opacity(0.18))
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12)).foregroundStyle(Color.driftMuted2)
            Text(value)
                .font(.system(size: 17, weight: .bold).monospacedDigit())
                .foregroundStyle(Color.driftText)
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
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.driftText)
                .padding(.leading, 10)
            if !allSelected {
                Button("Select all", action: selectAll)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.driftAccentInk)
                    .padding(.horizontal, 8)
            }
            Rectangle().fill(Color.driftLine).frame(width: 1, height: 18).padding(.horizontal, 4)
            IconButton(symbol: "folder", label: "Move to folder…", tint: .driftMuted2, fill: .driftField, size: 34, action: move)
            IconButton(symbol: "trash", label: "Delete", tint: .driftDanger, fill: .driftDangerWash, size: 34, action: delete)
            IconButton(symbol: "xmark", label: "Clear selection", tint: .driftMuted, fill: .clear, size: 34, action: clear)
        }
        .padding(6)
        .padding(.leading, 6)
        .background(Color.driftWindow, in: .capsule)
        .overlay(Capsule().strokeBorder(Color.driftLine))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 10)
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
    }
}

// MARK: - Clipboard banner

private struct ClipboardBanner: View {
    @Environment(DownloadStore.self) private var store
    let url: URL

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.driftAccent)
                .frame(width: 34, height: 34)
                .background(Color.driftAccentWash, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("Download link on your clipboard")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.driftText)
                Text(url.scheme == "magnet" ? "Magnet link" : url.absoluteString)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.driftMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Dismiss") { store.clipboardSuggestion = nil }
                .buttonStyle(.driftPlain)
            Button("Add") {
                store.addRequest = AddRequest(url: url.absoluteString)
                store.clipboardSuggestion = nil
            }
            .buttonStyle(.driftPrimary)
        }
        .padding(12)
        .background(Color.driftCard, in: .rect(cornerRadius: 14))
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

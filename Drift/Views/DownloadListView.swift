import SwiftUI
import Charts

struct DownloadListView: View {
    @Environment(DownloadStore.self) private var store
    let filter: SidebarFilter
    var sidebarHidden = false
    var toggleSidebar: () -> Void = {}

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
            .padding(.top, 4)
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
        .safeAreaInset(edge: .top, spacing: 0) {
            HeaderBar(title: filter.title, subtitle: subtitle, search: $search,
                      sidebarHidden: sidebarHidden, toggleSidebar: toggleSidebar)
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

// MARK: - Header

/// In-window header, laid out like the original design: title and counts on the left;
/// search, the pause + sort pair, and Add on the right.
private struct HeaderBar: View {
    @Environment(DownloadStore.self) private var store
    let title: String
    let subtitle: String
    @Binding var search: String
    let sidebarHidden: Bool
    let toggleSidebar: () -> Void
    @FocusState private var searchFocused: Bool
    @Environment(\.openSettings) private var openSettings

    private var anyRunning: Bool { store.activeCount + store.queuedCount > 0 }

    var body: some View {
        @Bindable var settings = store.settings
        HStack(spacing: 12) {
            if sidebarHidden {
                IconButton(symbol: "sidebar.left", label: "Show Sidebar", tint: .driftMuted2, fill: .clear, size: 30,
                           action: toggleSidebar)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.driftText)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Color.driftMuted)
                }
            }
            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.driftMuted)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color.driftMuted.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(width: 220, height: 32)
            .background(Color.driftField, in: .capsule)
            .overlay(Capsule().strokeBorder(searchFocused ? Color.driftAccent : Color.driftLine))

            HStack(spacing: 2) {
                Button {
                    anyRunning ? store.pauseAll() : store.resumeAll()
                } label: {
                    Image(systemName: anyRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 28)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .help(anyRunning ? "Pause all downloads" : "Resume all downloads")
                .accessibilityLabel(anyRunning ? "Pause All" : "Resume All")

                Menu {
                    Picker("Sort By", selection: $settings.sortOrder) {
                        ForEach(SortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    SlidersIcon()
                        .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .frame(width: 15, height: 15)
                        .frame(width: 32, height: 28)
                        .contentShape(.capsule)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort downloads")
                .accessibilityLabel("Sort")
            }
            .foregroundStyle(Color.driftText)
            .padding(3)
            .background(Color.driftField, in: .capsule)
            .overlay(Capsule().strokeBorder(Color.driftLine))

            Button {
                store.addRequest = AddRequest()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                    Text("Add")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.leading, 10)
                .padding(.trailing, 14)
                .frame(height: 32)
                .background(Color.driftAccentStrong, in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .help("New download (⌘N)")

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.driftText)
                    .frame(width: 32, height: 32)
                    .background(Color.driftField, in: .circle)
                    .overlay(Circle().strokeBorder(Color.driftLine))
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
        }
        .padding(.leading, sidebarHidden ? 76 : 20)
        .padding(.trailing, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .background(Color.driftWindow)
        .gesture(WindowDragGesture())
    }
}

/// The sort icon from the design: two horizontal sliders with knobs.
private struct SlidersIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 16
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(2, 4.5)); path.addLine(to: p(9, 4.5))
        path.move(to: p(12, 4.5)); path.addLine(to: p(14, 4.5))
        path.move(to: p(2, 11.5)); path.addLine(to: p(4, 11.5))
        path.move(to: p(7, 11.5)); path.addLine(to: p(14, 11.5))
        path.addEllipse(in: CGRect(origin: p(9, 3), size: CGSize(width: 3 * s, height: 3 * s)))
        path.addEllipse(in: CGRect(origin: p(4, 10), size: CGSize(width: 3 * s, height: 3 * s)))
        return path
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

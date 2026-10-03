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
    @State private var panelWidth: CGFloat = 440
    @State private var spaceMonitor: Any?

    private var visible: [DownloadItem] { store.items(for: filter, search: search) }

    var body: some View {
        @Bindable var settings = store.settings
        let items = visible

        VStack(spacing: 0) {
        ScrollView {
            VStack(spacing: 14) {
                if let link = store.clipboardSuggestion {
                    ClipboardBanner(url: link)
                }
                if store.settings.showSpeedStrip {
                    ThroughputCard()
                }
                if items.isEmpty {
                    EmptyState(filter: filter, searching: !search.isEmpty)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { item in
                            DownloadRow(item: item, isSelected: selectionBinding(item.id),
                                        isFocused: store.focusedID == item.id) {
                                withAnimation(.snappy(duration: 0.22)) { store.focusedID = store.focusedID == item.id ? nil : item.id }
                            }
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
                                 delete: { confirmDelete = true },
                                 toggle: toggleSelection,
                                 anyRunning: selectionRunning)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.22), value: selection.isEmpty)
        }
        }
        .overlay(alignment: .trailing) {
            ZStack {
                if let id = store.focusedID, let item = store.item(id) {
                    DetailsPanel(item: item, width: $panelWidth) {
                        withAnimation(.snappy(duration: 0.25)) { store.focusedID = nil }
                    }
                    .transition(.move(edge: .trailing))
                }
            }
            .animation(.snappy(duration: 0.25), value: store.focusedID)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HeaderBar(title: filter.title, subtitle: subtitle, search: $search,
                      sidebarHidden: sidebarHidden, toggleSidebar: toggleSidebar)
        }
        .onAppear {
            spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Space in the main window, unless typing in a text field: pause or resume.
                guard event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                      let window = event.window, window.title == "Drift", window.attachedSheet == nil,
                      !(window.firstResponder is NSText) else { return event }
                let targets = selection.isEmpty ? (store.focusedID.map { [$0] } ?? []) : Array(selection)
                guard !targets.isEmpty else { return event }
                for id in targets { store.toggle(id) }
                return nil
            }
        }
        .onDisappear {
            if let spaceMonitor { NSEvent.removeMonitor(spaceMonitor) }
            spaceMonitor = nil
        }
        .onChange(of: filter) { selection.removeAll() }
        .onChange(of: store.items.map(\.id)) { _, ids in
            selection.formIntersection(ids)
            if let id = store.focusedID, !ids.contains(id) { store.focusedID = nil }
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
        let paused = store.items.count { $0.state == .paused }
        var parts: [String] = []
        if store.activeCount > 0 { parts.append("\(store.activeCount) downloading") }
        if paused > 0 { parts.append("\(paused) paused") }
        if store.queuedCount > 0 { parts.append("\(store.queuedCount) queued") }
        return parts.joined(separator: " · ")
    }

    private func selectionBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { selection.contains(id) },
            set: { if $0 { selection.insert(id) } else { selection.remove(id) } }
        )
    }

    private var selectionRunning: Bool {
        store.items.contains { selection.contains($0.id) && ($0.state.isActive || $0.state == .queued) }
    }

    /// Pauses the selection if anything in it is running, otherwise resumes it.
    private func toggleSelection() {
        let running = selectionRunning
        for id in selection {
            guard let item = store.item(id), !item.state.isFinished else { continue }
            if running { store.pause(id) } else if item.state.isFailed { store.retry(id) } else { store.resume(id) }
        }
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
                    .font(.system(size: 20, weight: .bold))
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

/// Slim speed strip: total speed, live line chart, what's left, and the add shortcut.
struct ThroughputCard: View {
    @Environment(DownloadStore.self) private var store

    var body: some View {
        let parts = Format.speedParts(store.totalSpeed)
        let remaining = store.remainingBytes
        let history = Array(store.speedHistory.enumerated())
        let peak = max(1, store.speedHistory.max() ?? 1)
        HStack(spacing: 22) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(parts.value)
                    .font(.system(size: 22, weight: .heavy).monospacedDigit())
                    .tracking(-0.4)
                    .foregroundStyle(Color.driftText)
                    .contentTransition(.numericText())
                Text(parts.unit)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.driftMuted2)
            }
            .frame(minWidth: 110, alignment: .leading)

            Chart(history, id: \.offset) { point in
                LineMark(x: .value("t", point.offset), y: .value("speed", point.element))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(store.totalSpeed > 0 ? Color.driftAccent : Color.driftTrack)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            // Leave room below zero so an idle line floats in the strip instead of hugging its bottom edge.
            .chartYScale(domain: -peak * 0.7...peak * 1.15)
            .frame(height: 26)

            Text(store.activeCount > 0 ? "\(Format.bytes(remaining)) left" : "Nothing downloading")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Color.driftMuted2)
                .fixedSize()
            if store.totalSpeed > 1 {
                Text("done in \(Format.duration(Double(remaining) / store.totalSpeed))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Color.driftMuted2)
                    .fixedSize()
            }
            HStack(spacing: 4) {
                KeyHint("⌘N").help("New download")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.driftLine))
    }
}

private struct KeyHint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.driftMuted2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.driftField, in: .rect(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.driftLine))
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
    var toggle: (() -> Void)? = nil
    var anyRunning = false

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.driftAccent)
                    .frame(width: 16, height: 16)
                    .overlay(Image(systemName: "checkmark").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(.white))
                Text("\(count) selected")
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.driftText)
            }
            .padding(.leading, 6)
            if !allSelected {
                Button("Select all", action: selectAll)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.driftAccentInk)
                    .padding(.horizontal, 6)
            }
            Rectangle().fill(Color.driftLine).frame(width: 1, height: 16).padding(.horizontal, 4)
            if let toggle {
                BarButton(title: anyRunning ? "Pause" : "Resume", symbol: anyRunning ? "pause.fill" : "play.fill",
                          ink: anyRunning ? .driftText : .driftAccentStrong, wash: anyRunning ? .driftField : .driftAccentWash,
                          action: toggle)
            }
            BarButton(title: "Move", symbol: "folder", ink: .driftText, wash: .driftField, action: move)
            BarButton(title: "Delete", symbol: "trash", ink: .driftDanger, wash: .driftDangerWash, action: delete)
            IconButton(symbol: "xmark", label: "Clear selection", tint: .driftMuted, fill: .clear, size: 26,
                       glyphScale: 0.38, action: clear)
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background(Color.driftWindow, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.driftLine))
        .shadow(color: .black.opacity(0.10), radius: 14, y: 8)
        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }
}

/// Compact labeled button for the selection bar.
private struct BarButton: View {
    let title: String
    let symbol: String
    let ink: Color
    let wash: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(wash.opacity(hovering ? 1 : 0.85), in: .rect(cornerRadius: 7))
            .contentShape(.rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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

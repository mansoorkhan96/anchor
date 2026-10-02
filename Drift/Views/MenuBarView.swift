import SwiftUI
import Charts

struct MenuBarView: View {
    @Environment(DownloadStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    private var active: [DownloadItem] {
        Array(store.items.filter { $0.state.isActive }.prefix(5))
    }

    var body: some View {
        let parts = Format.speedParts(store.totalSpeed)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drift").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(parts.value)
                            .font(.system(size: 30, weight: .light, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText())
                        Text(parts.unit).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Chart(Array(store.speedHistory.suffix(40).enumerated()), id: \.offset) { point in
                    LineMark(x: .value("t", point.offset), y: .value("v", point.element))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Color.driftAccent)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: 0...max(1, (store.speedHistory.suffix(40).max() ?? 1) * 1.15))
                .frame(width: 120, height: 36)
            }

            Divider()

            if active.isEmpty {
                Text("No active downloads")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(active) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.fileName).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(Format.speed(item.speed)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            ProgressView(value: item.progress)
                                .progressViewStyle(.linear)
                                .tint(item.kind == .torrent ? .driftTorrent : .driftAccent)
                            Text(detail(item)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()

            VStack(spacing: 2) {
                MenuButton(title: "Add from Clipboard", symbol: "plus", shortcut: "⌘⇧V") {
                    let text = NSPasteboard.general.string(forType: .string) ?? ""
                    showMain()
                    store.addRequest = AddRequest(url: text)
                }
                MenuButton(title: store.activeCount + store.queuedCount > 0 ? "Pause All" : "Resume All",
                           symbol: store.activeCount + store.queuedCount > 0 ? "pause" : "play") {
                    store.activeCount + store.queuedCount > 0 ? store.pauseAll() : store.resumeAll()
                }
                MenuButton(title: "Open Drift", symbol: "macwindow") { showMain() }
                MenuButton(title: "Quit Drift", symbol: "power", shortcut: "⌘Q") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func detail(_ item: DownloadItem) -> String {
        let size = Format.progress(item.receivedBytes, of: item.totalBytes)
        guard let eta = item.eta else { return size }
        return "\(size) · \(Format.duration(eta)) left"
    }

    private func showMain() {
        openWindow(id: "main")
        NSApp.activate()
    }
}

private struct MenuButton: View {
    let title: String
    let symbol: String
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16)
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.secondary).font(.callout) }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(hovering ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

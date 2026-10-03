import SwiftUI
import Charts

struct MenuBarView: View {
    @Environment(DownloadStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    private var active: [DownloadItem] {
        Array(store.items.filter { $0.state.isActive }.prefix(5))
    }

    private var anyRunning: Bool { store.activeCount + store.queuedCount > 0 }

    var body: some View {
        let parts = Format.speedParts(store.totalSpeed)
        let history = Array(store.speedHistory.suffix(40).enumerated())
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.activeCount > 0 ? "Drift · \(store.activeCount) active" : "Drift")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.driftAccentInk)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(parts.value)
                            .font(.system(size: 30, weight: .heavy).monospacedDigit())
                            .tracking(-0.8)
                            .foregroundStyle(Color.driftText)
                            .contentTransition(.numericText())
                        Text(parts.unit)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.driftMuted)
                    }
                }
                Spacer()
                Chart(history, id: \.offset) { point in
                    AreaMark(x: .value("t", point.offset), y: .value("v", point.element))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(colors: [Color.driftAccent.opacity(0.2), Color.driftAccent.opacity(0)],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("t", point.offset), y: .value("v", point.element))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Color.driftAccent)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: 0...max(1, (store.speedHistory.suffix(40).max() ?? 1) * 1.15))
                .frame(width: 120, height: 38)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.driftCard, in: .rect(cornerRadius: 12))

            if active.isEmpty {
                Text("No active downloads")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.driftMuted)
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(active) { item in
                        HStack(spacing: 10) {
                            FileTile(item: item, size: 30)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 10) {
                                    Text(item.fileName)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(Color.driftText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Text(Format.speed(item.speed))
                                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                                        .foregroundStyle(Color.driftMuted2)
                                }
                                ProgressLine(fraction: item.progress,
                                             color: item.kind == .torrent ? .driftTorrent : .driftAccent, height: 4)
                                Text(detail(item))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(Color.driftMuted)
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }

            VStack(spacing: 2) {
                MenuButton(title: "Add from Clipboard", symbol: "plus", shortcut: "⌘⇧V", prominent: true) {
                    let text = NSPasteboard.general.string(forType: .string) ?? ""
                    showMain()
                    store.addRequest = AddRequest(url: text)
                }
                MenuButton(title: anyRunning ? "Pause All" : "Resume All", symbol: anyRunning ? "pause" : "play") {
                    anyRunning ? store.pauseAll() : store.resumeAll()
                }
                MenuButton(title: "Open Drift", symbol: "macwindow") { showMain() }
                MenuButton(title: "Quit", symbol: "power", shortcut: "⌘Q", muted: true) { NSApp.terminate(nil) }
            }
            .padding(.top, 10)
            .overlay(alignment: .top) { Rectangle().fill(Color.driftLine).frame(height: 1) }
        }
        .padding(16)
        .frame(width: 340)
        .background(Color.driftWindow)
    }

    private func detail(_ item: DownloadItem) -> String {
        let size = Format.progress(item.receivedBytes, of: item.totalBytes)
        let prefix = item.kind == .torrent ? "Torrent · " : ""
        guard let eta = item.eta else { return prefix + size }
        return "\(prefix)\(size) · \(Format.duration(eta)) left"
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
    var prominent = false
    var muted = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: prominent ? .semibold : .regular))
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(prominent ? Color.driftAccent : Color.driftMuted)
                }
            }
            .foregroundStyle(prominent ? Color.driftAccentInk : muted ? Color.driftMuted : Color.driftText)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(background, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        if prominent { return hovering ? .driftAccentTint : .driftAccentWash }
        return hovering ? .driftField : .clear
    }
}

import SwiftUI
import Charts

struct MenuBarView: View {
    @Environment(DownloadStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    private var anyRunning: Bool { store.activeCount + store.queuedCount > 0 }
    private var downloading: Bool { store.activeCount > 0 || store.totalSpeed > 0 }

    var body: some View {
        @Bindable var settings = store.settings
        let recent = store.recentItems(order: settings.menuBarOrder, limit: settings.menuBarCount)
        VStack(alignment: .leading, spacing: 14) {
            if downloading {
                speedCard
            } else {
                HStack {
                    Text("Drift")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.driftText)
                    Spacer()
                    Text(store.queuedCount > 0 ? "\(store.queuedCount) queued" : "Nothing downloading")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.driftMuted)
                }
                .padding(.horizontal, 4)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Downloads")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.driftText)
                    Spacer()
                    OrderTabs(selection: $settings.menuBarOrder)
                }
                .padding(.horizontal, 4)

                if recent.isEmpty {
                    Text("No downloads yet")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.driftMuted)
                        .frame(maxWidth: .infinity, minHeight: 56)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(recent) { item in
                                RecentRow(item: item)
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 380)
                    .fixedSize(horizontal: false, vertical: recent.count <= 6)
                }
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

    private var speedCard: some View {
        let parts = Format.speedParts(store.totalSpeed)
        let history = Array(store.speedHistory.suffix(40).enumerated())
        return HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Drift · \(store.activeCount) active")
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
    }

    private func showMain() {
        openWindow(id: "main")
        NSApp.activate()
    }
}

/// Compact segmented control: light track, white selected pill with a soft shadow.
private struct OrderTabs: View {
    @Binding var selection: MenuBarOrder
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            tab(.newest, title: "Newest")
            tab(.unfinishedFirst, title: "Unfinished")
        }
        .padding(2)
        .background(Color.driftField, in: .rect(cornerRadius: 8))
    }

    private func tab(_ order: MenuBarOrder, title: String) -> some View {
        let on = selection == order
        return Button {
            withAnimation(.snappy(duration: 0.2)) { selection = order }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? Color.driftAccentInk : Color.driftMuted)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.driftWindow)
                            .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                            .matchedGeometryEffect(id: "pill", in: pill)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(order == .newest ? "Newest downloads first" : "Unfinished downloads first, newest first")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct RecentRow: View {
    @Environment(DownloadStore.self) private var store
    let item: DownloadItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            FileTile(item: item, size: 30)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Text(item.fileName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.driftText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if item.state == .downloading {
                        Text(Format.speed(item.speed))
                            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(Color.driftMuted2)
                    } else {
                        StatusPill(state: item.state, compact: true)
                    }
                }
                if !item.state.isFinished {
                    ProgressLine(fraction: item.progress, color: barColor, height: 4)
                }
                Text(detail)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color.driftMuted)
                    .lineLimit(1)
            }
            action
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .background(hovering ? Color.driftField : .clear, in: .rect(cornerRadius: 9))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { if item.state.isFinished { store.open(item.id) } }
        .help(item.state.isFinished ? "Open \(item.fileName)" : item.fileName)
    }

    @ViewBuilder private var action: some View {
        switch item.state {
        case .downloading, .connecting, .queued:
            IconButton(symbol: "pause.fill", label: "Pause", size: 26) { store.toggle(item.id) }
        case .paused:
            IconButton(symbol: "play.fill", label: "Resume", tint: .driftAccentInk, fill: .driftAccentWash, size: 26) { store.toggle(item.id) }
        case .failed:
            IconButton(symbol: "arrow.clockwise", label: "Retry", tint: .driftDanger, fill: .driftDangerWash, size: 26) { store.retry(item.id) }
        case .completed:
            IconButton(symbol: "magnifyingglass", label: "Show in Finder", size: 26) { store.reveal(item.id) }
        }
    }

    private var barColor: Color {
        switch item.state {
        case .paused: .driftPaused
        case .failed: .driftDanger
        default: item.kind == .torrent ? .driftTorrent : .driftAccent
        }
    }

    private var detail: String {
        let size = Format.progress(item.receivedBytes, of: item.totalBytes)
        let prefix = item.kind == .torrent ? "Torrent · " : ""
        switch item.state {
        case .completed:
            let when = (item.completedAt ?? item.createdAt).formatted(.relative(presentation: .named))
            return "\(prefix)\(Format.bytes(item.totalBytes ?? item.receivedBytes)) · \(when)"
        case .downloading:
            guard let eta = item.eta else { return prefix + size }
            return "\(prefix)\(size) · \(Format.duration(eta)) left"
        default:
            return prefix + size
        }
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

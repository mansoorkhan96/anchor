import SwiftUI

struct DownloadRow: View {
    @Environment(DownloadStore.self) private var store
    let item: DownloadItem
    @Binding var isSelected: Bool
    @State private var hovering = false

    private var tint: Color { item.kind == .torrent ? .driftTorrent : item.category.color }

    private var barColor: Color {
        switch item.state {
        case .paused: .driftPaused
        case .failed: .red
        default: item.kind == .torrent ? .driftTorrent : .driftAccent
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            FileTile(fileName: item.fileName, tint: tint, isTorrent: item.kind == .torrent)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(item.fileName)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(item.state.isActive ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(meta)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(item.state.isFailed ? Color.red : .secondary)
                        .lineLimit(1)
                }
                if !item.state.isFinished {
                    SegmentBar(item: item, color: barColor)
                        .frame(height: 5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(speedText)
                .font(.system(size: 12.5).monospacedDigit())
                .foregroundStyle(item.state.isActive ? .primary : speedColor)
                .frame(width: 92, alignment: .trailing)
                .contentTransition(.numericText())

            Text(item.eta.map(Format.duration) ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)

            actionButton

            Toggle("Select \(item.fileName)", isOn: $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(background, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(border))
        .contentShape(.rect(cornerRadius: 12))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { item.state.isFinished ? store.open(item.id) : store.toggle(item.id) }
        .contextMenu { menu }
    }

    private var background: Color {
        if isSelected { return Color.driftAccent.opacity(0.12) }
        if item.state.isActive || hovering { return Color.primary.opacity(hovering ? 0.06 : 0.045) }
        return .clear
    }

    private var border: Color {
        isSelected ? Color.driftAccent.opacity(0.45) : Color.primary.opacity(item.state.isActive ? 0.07 : 0.05)
    }

    private var meta: String {
        let size = Format.progress(item.receivedBytes, of: item.totalBytes)
        switch item.state {
        case .connecting: return "Connecting…"
        case .downloading:
            if item.kind == .torrent {
                return item.totalBytes == nil ? "Torrent · fetching metadata · \(item.peers) peers" : "Torrent · \(size) · \(item.peers) peers"
            }
            return "\(size) · \(item.connections) connection\(item.connections == 1 ? "" : "s")"
        case .queued: return "Queued" + (item.totalBytes.map { " · \(Format.bytes($0))" } ?? "")
        case .paused: return "Paused · \(size)"
        case .failed(let reason): return reason
        case .completed:
            let total = Format.bytes(item.totalBytes ?? item.receivedBytes)
            let when = (item.completedAt ?? item.createdAt).formatted(.relative(presentation: .named))
            return "\(total) · \(item.url.host() ?? "torrent") · \(when)"
        }
    }

    private var speedText: String {
        switch item.state {
        case .downloading: Format.speed(item.speed)
        case .connecting, .queued: "Waiting"
        case .paused: "Paused"
        case .failed: "Failed"
        case .completed: ""
        }
    }

    private var speedColor: Color {
        switch item.state {
        case .paused: .driftPaused
        case .failed: .red
        default: .secondary
        }
    }

    @ViewBuilder private var actionButton: some View {
        let (symbol, label): (String, String) = switch item.state {
        case .downloading, .connecting, .queued: ("pause.fill", "Pause")
        case .paused: ("play.fill", "Resume")
        case .failed: ("arrow.clockwise", "Retry")
        case .completed: ("magnifyingglass", "Show in Finder")
        }
        Button {
            switch item.state {
            case .completed: store.reveal(item.id)
            case .failed: store.retry(item.id)
            default: store.toggle(item.id)
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.08), in: .circle)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder private var menu: some View {
        if item.state.isFinished {
            Button("Open") { store.open(item.id) }
        }
        Button("Show in Finder") { store.reveal(item.id) }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
        }
        Divider()
        switch item.state {
        case .downloading, .connecting, .queued: Button("Pause") { store.pause(item.id) }
        case .paused: Button("Resume") { store.resume(item.id) }
        case .failed: Button("Retry") { store.retry(item.id) }
        case .completed: EmptyView()
        }
        Divider()
        Button("Remove from List") { store.remove([item.id], deleteFiles: false) }
        Button("Move to Trash", role: .destructive) { store.remove([item.id], deleteFiles: true) }
    }
}

struct FileTile: View {
    @Environment(\.colorScheme) private var colorScheme
    let fileName: String
    let tint: Color
    var isTorrent = false
    var size: CGFloat = 40

    private var label: String {
        let ext = (fileName as NSString).pathExtension.uppercased()
        if !ext.isEmpty, ext.count <= 4 { return ext }
        return isTorrent ? "BT" : "FILE"
    }

    var body: some View {
        Text(label)
            .font(.system(size: size * 0.25, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(colorScheme == .light ? tint.mix(with: .black, by: 0.4) : tint)
            .frame(width: size, height: size)
            .background(tint.opacity(colorScheme == .light ? 0.2 : 0.14), in: .rect(cornerRadius: size * 0.25))
    }
}

/// FDM-style bar: one chunk per connection segment, each filled by how much of it has arrived.
struct SegmentBar: View {
    let item: DownloadItem
    let color: Color

    var body: some View {
        Canvas { context, size in
            let track = Color.primary.opacity(0.09)
            let segments = item.segments.sorted { $0.start < $1.start }
            let total = Double(item.totalBytes ?? 0)

            guard item.kind == .http, total > 0, segments.count > 1 else {
                draw(context, CGRect(origin: .zero, size: size), fraction: item.progress, track: track)
                return
            }

            let gap: CGFloat = segments.count > 40 ? 0 : 2
            let usable = size.width - gap * CGFloat(segments.count - 1)
            var x: CGFloat = 0
            for segment in segments {
                let width = max(1, usable * CGFloat(Double(segment.length) / total))
                let fraction = Double(segment.received) / Double(max(1, segment.length))
                draw(context, CGRect(x: x, y: 0, width: width, height: size.height), fraction: fraction, track: track)
                x += width + gap
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(item.progress * 100)) percent")
    }

    private func draw(_ context: GraphicsContext, _ rect: CGRect, fraction: Double, track: Color) {
        let radius = min(2, rect.height / 2)
        context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(track))
        guard fraction > 0 else { return }
        var filled = rect
        filled.size.width = rect.width * CGFloat(min(1, fraction))
        context.fill(Path(roundedRect: filled, cornerRadius: radius), with: .color(color))
    }
}

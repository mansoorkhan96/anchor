import SwiftUI

struct DownloadRow: View {
    @Environment(DownloadStore.self) private var store
    let item: DownloadItem
    @Binding var isSelected: Bool
    var isFocused = false
    var onFocus: () -> Void = {}
    @State private var hovering = false

    private var barColor: Color {
        switch item.state {
        case .paused: .driftPaused
        case .failed: .driftDanger
        default: item.kind == .torrent ? .driftTorrent : .driftAccent
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            // Double-click lives on the file info only, so clicks on the buttons and checkbox never wait for it.
            HStack(spacing: 16) {
                FileTile(item: item)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(item.fileName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.driftText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let priority = item.priority, priority != .normal {
                            HStack(spacing: 3) {
                                Image(systemName: priority.symbol).font(.system(size: 8, weight: .bold))
                                Text(priority.title).font(.system(size: 10.5, weight: .semibold))
                            }
                            .foregroundStyle(priority == .high ? Color.driftAccentInk : Color.driftMuted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(priority == .high ? Color.driftAccentWash : Color.driftField, in: .capsule)
                            .help("\(priority.title) priority")
                        }
                        Text(meta)
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(item.state.isFailed ? Color.driftDanger : Color.driftMuted)
                            .lineLimit(1)
                    }
                    if !item.state.isFinished {
                        ProgressLine(fraction: item.progress, color: barColor)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }


            Group {
                if item.state == .downloading {
                    Text(Format.speed(item.speed))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.driftText)
                        .contentTransition(.numericText())
                } else {
                    StatusPill(state: item.state)
                }
            }
            .frame(width: 104, alignment: .trailing)

            Text(item.eta.map(Format.duration) ?? "")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Color.driftMuted)
                .frame(width: 64, alignment: .trailing)

            actionButton

            SelectionCheckbox(isOn: $isSelected, label: "Select \(item.fileName)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 12)
        .background(background, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(isSelected ? Color.driftAccentRing : isFocused ? Color.driftText.opacity(0.18) : .clear, lineWidth: 1))
        // Anywhere on the row except its buttons: one click shows details, a double click opens or pauses/resumes.
        // The click count comes from the mouse event, so single clicks fire immediately.
        .contentShape(.rect(cornerRadius: 14))
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                item.state.isFinished ? store.open(item.id) : store.toggle(item.id)
            } else {
                onFocus()
            }
        }
        .onHover { hovering = $0 }
        .contextMenu { menu }
    }

    private var background: Color {
        if isSelected { return .driftAccentWash }
        if hovering || isFocused { return .driftField }
        return item.state.isFinished || item.state == .queued || item.state == .paused ? .driftCardQuiet : .driftCard
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
        case .queued: return item.receivedBytes > 0 ? size : (item.totalBytes.map(Format.bytes) ?? "Waiting for a free slot")
        case .paused: return size
        case .failed(let reason): return reason
        case .completed:
            let total = Format.bytes(item.totalBytes ?? item.receivedBytes)
            let when = (item.completedAt ?? item.createdAt).formatted(.relative(presentation: .named))
            return "\(total) · \(item.url.host() ?? "torrent") · \(when)"
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch item.state {
        case .downloading, .connecting, .queued:
            IconButton(symbol: "pause.fill", label: "Pause") { store.toggle(item.id) }
        case .paused:
            IconButton(symbol: "play.fill", label: "Resume", tint: .driftAccentInk, fill: .driftAccentWash) { store.toggle(item.id) }
        case .failed:
            IconButton(symbol: "arrow.clockwise", label: "Retry", tint: .driftDanger, fill: .driftDangerWash) { store.retry(item.id) }
        case .completed:
            RevealButton { store.reveal(item.id) }
        }
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
        case .paused:
            Button("Resume") { store.resume(item.id) }
            Button("Add to Queue") { store.queue([item.id]) }
        case .failed:
            Button("Retry") { store.retry(item.id) }
            Button("Add to Queue") { store.queue([item.id]) }
        case .completed: EmptyView()
        }
        Menu("Priority") {
            ForEach(Priority.allCases.reversed()) { option in
                Button {
                    store.setPriority([item.id], to: option)
                } label: {
                    if (item.priority ?? .normal) == option { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                }
            }
        }
        if item.files != nil || item.kind == .http {
            Button("Show Details") { onFocus() }
        }
        Divider()
        Button("Remove from List") { store.remove([item.id], deleteFiles: false) }
        Button("Move to Trash", role: .destructive) { store.remove([item.id], deleteFiles: true) }
    }
}

/// Square file badge: the extension in the category's ink on its soft wash.
struct FileTile: View {
    let fileName: String
    let ink: Color
    let wash: Color
    var isTorrent = false
    var size: CGFloat = 42

    init(fileName: String, category: FileCategory, isTorrent: Bool = false, size: CGFloat = 42) {
        self.fileName = fileName
        self.isTorrent = isTorrent
        self.size = size
        ink = isTorrent ? .adaptive(light: 0x2E8A62, dark: 0x8FDDB5) : category.ink
        wash = isTorrent ? .adaptive(light: 0xE6F4EE, dark: 0x1E3329) : category.wash
    }

    init(item: DownloadItem, size: CGFloat = 42) {
        self.init(fileName: item.fileName, category: item.category, isTorrent: item.kind == .torrent, size: size)
    }

    private var label: String {
        let ext = (fileName as NSString).pathExtension.uppercased()
        if !ext.isEmpty, ext.count <= 4 { return ext }
        return isTorrent ? "BT" : "FILE"
    }

    var body: some View {
        Text(label)
            .font(.system(size: max(8, size * 0.24), weight: .heavy))
            .tracking(0.5)
            .foregroundStyle(ink)
            .frame(width: size, height: size)
            .background(wash, in: .rect(cornerRadius: size * 0.29))
    }
}

/// Single rounded progress bar.
struct ProgressLine: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.driftTrack)
                Capsule()
                    .fill(color)
                    .frame(width: fraction > 0 ? max(height, geo.size.width * min(1, fraction)) : 0)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

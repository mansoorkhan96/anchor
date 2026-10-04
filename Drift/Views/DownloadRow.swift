import SwiftUI

struct DownloadRow: View {
    @Environment(DownloadStore.self) private var store
    let item: DownloadItem
    @Binding var isSelected: Bool
    var isFocused = false
    var onFocus: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            SelectionCheckbox(isOn: $isSelected, label: "Select \(item.fileName)")
                .padding(.horizontal, -4)
            StatusPie(item: item)
            HStack(spacing: 5) {
                if let priority = item.priority, priority != .normal {
                    Image(systemName: priority.symbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(priority == .high ? Color.driftAccentInk : Color.driftMuted)
                        .help("\(priority.title) priority")
                }
                if let kb = item.speedLimitKB, !item.state.isFinished {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.driftPausedInk)
                        .help("Limited to \(Format.speed(Double(kb * 1000)))")
                }
                Text(item.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.driftText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            CategoryTag(item: item)

            Text(item.seeding == true ? "↑ \(Format.speed(item.uploadSpeed))" : item.state == .downloading ? Format.speed(item.speed) : "")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(item.seeding == true ? Color.driftSuccess : Color.driftAccentStrong)
                .help(item.seeding == true ? "Seeding · \(Format.bytes(item.uploadedBytes)) uploaded" : "")
                .frame(width: 80, alignment: .trailing)
                .contentTransition(.numericText())
            Text(percentText)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Color.driftMuted)
                .frame(width: 38, alignment: .trailing)
            Text(sizeText)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(item.state.isFailed ? Color.driftDanger : Color.driftMuted2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 120, alignment: .trailing)
                .help(item.state.isFailed ? sizeText : "")

            actionButton
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(background, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.driftAccentEdge : .clear, lineWidth: 1))
        // Anywhere on the row except its buttons: one click shows details, a double click opens or pauses/resumes.
        // The click count comes from the mouse event, so single clicks fire immediately.
        .contentShape(.rect(cornerRadius: 8))
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
        if isFocused { return .driftField }
        return hovering ? .driftCard : .clear
    }

    private var percentText: String {
        guard !item.state.isFinished, item.totalBytes != nil else { return "" }
        return "\(Int(item.progress * 100))%"
    }

    private var sizeText: String {
        switch item.state {
        case .failed(let reason): return reason
        case .completed: return Format.bytes(item.totalBytes ?? item.receivedBytes)
        case .connecting where item.totalBytes == nil: return "Connecting…"
        default:
            guard let total = item.totalBytes, total > 0 else {
                return item.kind == .torrent && item.state.isActive ? "Fetching info…" : Format.bytes(item.receivedBytes)
            }
            return Format.progress(item.receivedBytes, of: total)
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch item.state {
        case .downloading, .connecting, .queued:
            IconButton(symbol: "pause.fill", label: "Pause", fill: .driftField, size: 26) { store.toggle(item.id) }
        case .paused:
            IconButton(symbol: "play.fill", label: "Resume", tint: .driftAccentStrong, fill: .driftAccentWash, size: 26) { store.toggle(item.id) }
        case .failed:
            IconButton(symbol: "arrow.clockwise", label: "Retry", tint: .driftDanger, fill: .driftDangerWash, size: 26) { store.retry(item.id) }
        case .completed:
            RevealButton(size: 26, outlined: true) { store.reveal(item.id) }
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
        if item.kind == .http, !item.state.isFinished {
            Button("Update Link…") {
                if let url = LinkPrompt.ask(for: item) { store.updateLink(item.id, to: url) }
            }
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
        if item.seeding == true {
            Button("Stop Seeding") { store.stopSeeding(item.id) }
        }
        if !item.state.isFinished {
            Menu("Speed Limit") {
                SpeedLimitMenuItems(current: item.speedLimitKB) { store.setSpeedLimit([item.id], kb: $0) }
            }
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

/// Linear-style status icon: a ring with a pie that fills with progress, in the state's color.
struct StatusPie: View {
    let item: DownloadItem

    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            switch item.state {
            case .completed:
                ctx.fill(Path(ellipseIn: rect.insetBy(dx: 1, dy: 1)), with: .color(.driftDone))
                var check = Path()
                check.move(to: CGPoint(x: size.width * 0.3, y: size.height * 0.51))
                check.addLine(to: CGPoint(x: size.width * 0.44, y: size.height * 0.64))
                check.addLine(to: CGPoint(x: size.width * 0.7, y: size.height * 0.37))
                ctx.stroke(check, with: .color(.white), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            case .failed:
                ctx.fill(Path(ellipseIn: rect.insetBy(dx: 1, dy: 1)), with: .color(.driftDanger))
                var bang = Path()
                bang.move(to: CGPoint(x: center.x, y: size.height * 0.28))
                bang.addLine(to: CGPoint(x: center.x, y: size.height * 0.56))
                ctx.stroke(bang, with: .color(.white), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                ctx.fill(Path(ellipseIn: CGRect(x: center.x - 1, y: size.height * 0.68, width: 2, height: 2)), with: .color(.white))
            default:
                let dashed = item.state == .queued || item.state == .connecting
                ctx.stroke(Path(ellipseIn: rect.insetBy(dx: 1.4, dy: 1.4)), with: .color(color),
                           style: StrokeStyle(lineWidth: 1.6, dash: dashed ? [2, 1.6] : []))
                let fraction = item.progress
                if fraction > 0 {
                    var pie = Path()
                    pie.move(to: center)
                    pie.addArc(center: center, radius: size.width * 0.28, startAngle: .degrees(-90),
                               endAngle: .degrees(-90 + 360 * min(1, fraction)), clockwise: false)
                    pie.closeSubpath()
                    ctx.fill(pie, with: .color(color))
                }
            }
        }
        .frame(width: 16, height: 16)
        .help(help)
    }

    private var color: Color {
        switch item.state {
        case .downloading: item.kind == .torrent ? .driftTorrent : .driftAccent
        case .connecting: .driftAccent
        case .paused: .driftPaused
        default: .driftQueued
        }
    }

    private var help: String {
        switch item.state {
        case .downloading: "Downloading"
        case .connecting: "Connecting"
        case .queued: "Queued"
        case .paused: "Paused"
        case .failed: "Failed"
        case .completed: "Done"
        }
    }
}

/// Small colored tag naming the download's kind.
struct CategoryTag: View {
    let item: DownloadItem

    var body: some View {
        let torrent = item.kind == .torrent
        Text(torrent ? "Torrent" : item.category.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(torrent ? Color.adaptive(light: 0x2E8A62, dark: 0x8FDDB5) : item.category.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(torrent ? Color.adaptive(light: 0xE6F4EE, dark: 0x1E3329) : item.category.wash, in: .rect(cornerRadius: 6))
            .fixedSize()
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

/// Asks for a replacement link for a download whose old link expired.
@MainActor
enum LinkPrompt {
    static func ask(for item: DownloadItem) -> URL? {
        let alert = NSAlert()
        alert.messageText = "Update Link"
        alert.informativeText = "Paste a new link for \(item.fileName). Drift keeps what's already downloaded if the file is the same size."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://…"
        let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        field.stringValue = clip.hasPrefix("http") ? clip : item.url.absoluteString
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}

/// Per-download speed cap choices, used in the row's context menu and the details panel.
struct SpeedLimitMenuItems: View {
    static let options: [Int?] = [nil, 256, 512, 1_000, 2_000, 5_000, 10_000]
    let current: Int?
    let choose: (Int?) -> Void

    var body: some View {
        ForEach(Self.options, id: \.self) { kb in
            Button {
                choose(kb)
            } label: {
                let title = kb.map { Format.speed(Double($0 * 1000)) } ?? "No Limit"
                if current == kb { Label(title, systemImage: "checkmark") } else { Text(title) }
            }
        }
    }
}

import SwiftUI

struct DownloadRow: View {
    @Environment(DownloadStore.self) private var store
    let item: DownloadItem
    @Binding var isSelected: Bool
    var isFocused = false
    /// Secondary line under the name: the cleanup reason, where it was archived from, or a pending move.
    var note: String?
    /// Set in the Cleanup and Archive lists: Move to Trash goes through their confirmation and file re-check
    /// instead of trashing right away.
    var onTrash: (() -> Void)?
    var onFocus: () -> Void = {}
    @State private var hovering = false

    private var locked: Bool { item.pendingMove != nil }

    var body: some View {
        HStack(spacing: 12) {
            SelectionCheckbox(isOn: $isSelected, label: "Select \(item.fileName)")
                .padding(.horizontal, -4)
            actionButton
            HStack(spacing: 5) {
                FileThumbnail(item: item)
                    .padding(.trailing, 4)
                if let priority = item.priority, priority != .normal {
                    Image(systemName: priority.symbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(priority == .high ? Color.anchorAccentInk : Color.anchorMuted)
                        .help("\(priority.title) priority")
                }
                if let kb = item.speedLimitKB, !item.state.isFinished {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.anchorPausedInk)
                        .help("Limited to \(Format.speed(Double(kb * 1000)))")
                }
                if item.keep == true {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.anchorMuted)
                        .help("Kept: never suggested for cleanup or archived")
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.fileName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.anchorText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let note {
                        Text(note)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.anchorMuted)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            CategoryTag(item: item)

            speedColumn
                .frame(width: 84, alignment: .trailing)
            Text(percentText)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Color.anchorMuted)
                .frame(width: 38, alignment: .trailing)
            Text(sizeText)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(item.state.isFailed ? Color.anchorDanger : Color.anchorMuted2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 120, alignment: .trailing)
                .help(item.state.isFailed ? sizeText : "")
        }
        .padding(.horizontal, 12)
        .frame(height: note == nil ? 40 : 50)
        .background(background, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.anchorAccentEdge : .clear, lineWidth: 1))
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

    /// HTTP: the download speed. Torrents: download and upload speeds on two lines, or only upload while seeding.
    @ViewBuilder private var speedColumn: some View {
        if item.kind == .torrent, item.state == .downloading || item.seeding == true {
            VStack(alignment: .trailing, spacing: 1) {
                if item.state == .downloading {
                    SpeedLabel(symbol: "arrow.down", speed: item.speed, color: .anchorAccentStrong)
                        .help("Downloading")
                }
                SpeedLabel(symbol: "arrow.up", speed: item.uploadSpeed, color: .anchorSuccess)
                    .help(item.seeding == true ? "Seeding · \(Format.bytes(item.uploadedBytes)) uploaded" : "Uploading to other peers")
            }
        } else {
            Text(item.state == .downloading ? Format.speed(item.speed) : "")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.anchorAccentStrong)
                .contentTransition(.numericText())
        }
    }

    private var background: Color {
        if isSelected { return .anchorAccentWash }
        if isFocused { return .anchorField }
        return hovering ? .anchorCard : .clear
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
            IconButton(symbol: "pause.fill", label: "Pause", tint: item.stateColor,
                       fill: item.stateColor.opacity(0.12), size: 26, glyphScale: 0.45) { store.toggle(item.id) }
                .overlay(ProgressRing(item: item))
        case .paused:
            IconButton(symbol: "play.fill", label: "Resume", tint: item.stateColor,
                       fill: item.stateColor.opacity(0.12), size: 26, glyphScale: 0.45) { store.toggle(item.id) }
                .overlay(ProgressRing(item: item))
        case .failed:
            IconButton(symbol: "arrow.clockwise", label: "Retry", tint: .anchorDanger, fill: .anchorDangerWash, size: 26) { store.retry(item.id) }
        case .completed:
            RevealButton(size: 26, outlined: true) { store.reveal(item.id) }
        }
    }

    @ViewBuilder private var menu: some View {
        if item.state.isFinished {
            Button("Open") { store.open(item.id) }
                .disabled(locked)
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
        if item.state.isFinished {
            Divider()
            Button(item.keep == true ? "Don't Keep" : "Keep") { store.setKeep([item.id], item.keep != true) }
                .disabled(locked)
            if item.archivedAt != nil {
                Button("Restore") { Task { await CleanupStore.shared.restore([item.id]) } }
                    .disabled(locked)
            }
        }
        Divider()
        Button("Remove from List") { store.remove([item.id], deleteFiles: false) }
            .disabled(locked)
        if let onTrash {
            Button("Move to Trash…", role: .destructive, action: onTrash)
                .disabled(locked)
        } else {
            Button("Move to Trash", role: .destructive) { store.remove([item.id], deleteFiles: true) }
                .disabled(locked)
        }
    }
}

extension DownloadItem {
    /// The state's color, used by the progress ring on Pause/Resume buttons.
    var stateColor: Color {
        switch state {
        case .downloading: kind == .torrent ? .anchorTorrent : .anchorAccent
        case .connecting: .anchorAccent
        case .paused: .anchorIdle
        default: .anchorQueued
        }
    }
}

/// A ring around a Pause/Resume button that fills with progress, in the state's color.
/// Both strokes sit flush with the button's outer edge and grow inward. Dashed while queued or connecting.
struct ProgressRing: View {
    let item: DownloadItem
    private let track: CGFloat = 1.5
    private let arc: CGFloat = 2.5

    var body: some View {
        let color = item.stateColor
        let dashed = item.state == .queued || item.state == .connecting
        ZStack {
            Circle()
                .stroke(color.opacity(0.25), style: StrokeStyle(lineWidth: track, dash: dashed ? [2.5, 2] : []))
                .padding(track / 2)
            Circle()
                .trim(from: 0, to: min(1, max(0, item.progress)))
                .stroke(color, style: StrokeStyle(lineWidth: arc, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(arc / 2)
                .animation(.linear(duration: 0.4), value: item.progress)
        }
        .allowsHitTesting(false)
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
                Capsule().fill(Color.anchorTrack)
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

/// A small arrow and speed, used for a torrent's download and upload rates.
private struct SpeedLabel: View {
    let symbol: String
    let speed: Double
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
            Text(Format.speed(speed))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
        }
        .foregroundStyle(color)
        .lineLimit(1)
    }
}

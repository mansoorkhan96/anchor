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
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(item.fileName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.anchorText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(sizeText)
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(item.state.isFailed ? Color.anchorDanger : Color.anchorMuted2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 260, alignment: .trailing)
                            .fixedSize(horizontal: !item.state.isFailed, vertical: false)
                            .help(item.state.isFailed ? sizeText : "")
                    }
                    StatusLine(item: item)
                    if let note {
                        Text(note)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.anchorMuted)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: 40 + (ProgressStatus(item: item).stage() == nil ? 0 : 12) + (note == nil ? 0 : 12))
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

    private var background: Color {
        if isSelected { return .anchorAccentWash }
        if isFocused { return .anchorField }
        return hovering ? .anchorCard : .clear
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
        case .paused:
            IconButton(symbol: "play.fill", label: "Resume", tint: item.stateColor,
                       fill: item.stateColor.opacity(0.12), size: 26, glyphScale: 0.45) { store.toggle(item.id) }
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
        if item.files != nil || item.kind != .torrent {
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
    /// The state's color, used by the Pause/Resume buttons and the progress line.
    var stateColor: Color {
        switch state {
        case .downloading: kind == .torrent ? .anchorTorrent : .anchorAccent
        case .connecting: .anchorAccent
        case .paused: .anchorIdle
        default: .anchorQueued
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
        alert.informativeText = "Paste a new link for \(item.fileName). Anchor keeps what's already downloaded if the file is the same size."
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

/// The line under a download's name, in the main window and the menu bar: the stage chip, a thin bar and the
/// numbers. Nothing once the download has finished. `compact` (the menu bar) shortens the wording.
struct StatusLine: View {
    let item: DownloadItem
    var compact = false

    var body: some View {
        let status = ProgressStatus(item: item)
        if let stage = status.stage(short: compact) {
            HStack(spacing: 8) {
                StageChip(text: stage, status: status, compact: true)
                if status.showsBar {
                    ThinBar(status: status)
                } else {
                    Spacer(minLength: 0)
                }
                let detail = compact ? status.compactDetail : status.detail
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Color.anchorMuted2)
                        .lineLimit(1)
                        .fixedSize()
                        .contentTransition(.numericText())
                }
            }
            .help(item.mediaPhase?.detail ?? "")
        }
    }
}

/// What a download is doing, worded and colored the same in the main window and the menu bar.
struct ProgressStatus {
    let item: DownloadItem

    /// nil once finished. `short` trims "Converting to MP4" for narrow places.
    func stage(short: Bool = false) -> String? {
        if item.seeding == true { return "Seeding" }
        switch item.state {
        case .completed: return nil
        case .failed: return "Failed"
        case .queued: return "Queued"
        case .connecting: return "Connecting"
        case .paused:
            switch item.mediaPhase {
            case .merging where !short: return "Merging paused"
            case .converting where !short: return "Conversion paused"
            default: return "Paused"
            }
        case .downloading:
            switch item.mediaPhase {
            case .merging: return "Merging"
            case .converting: return short ? "Converting" : "Converting to MP4"
            case .processing: return "Processing"
            case nil: return "Downloading"
            }
        }
    }

    var color: Color {
        if item.seeding == true { return .anchorTorrent }
        switch item.state {
        case .failed: return .anchorDanger
        default: return item.stateColor
        }
    }

    var ink: Color {
        switch item.state {
        case .failed: .anchorDanger
        case .downloading where item.kind == .torrent: .anchorSuccess
        case .downloading, .connecting: .anchorAccentInk
        case .paused: .anchorIdleInk
        default: item.seeding == true ? .anchorSuccess : .anchorMuted2
        }
    }

    var fraction: Double { item.mediaPhase == .merging ? 1 : min(1, max(0, item.progress)) }
    var dimmed: Bool { item.mediaPhase == .merging }
    var showsBar: Bool { item.seeding != true && !item.state.isFailed && item.state != .queued }

    private var percent: String? {
        let converting = item.mediaPhase.map { if case .converting(_?, _) = $0 { true } else { false } } ?? false
        return (item.totalBytes ?? 0) > 0 || converting ? "\(Int(item.progress * 100))%" : nil
    }

    private var silent: Bool { item.state.isFailed || item.state == .queued }

    /// "38% · 8.4 MB/s", "42% · 1m 12s left" while converting, the upload speed while seeding.
    var detail: String {
        if item.seeding == true { return "↑ \(Format.speed(item.uploadSpeed))" }
        guard !silent else { return "" }
        var parts: [String] = []
        switch item.mediaPhase {
        case .merging, .processing:
            break
        case .converting(_, let eta):
            parts = [percent, item.state == .paused ? nil : eta.map { "\(Format.duration($0)) left" }].compactMap { $0 }
        case nil:
            parts = [percent].compactMap { $0 }
            if item.state == .downloading {
                if item.kind == .torrent {
                    parts.append("↓ \(Format.speed(item.speed))")
                    if item.uploadSpeed > 0 { parts.append("↑ \(Format.speed(item.uploadSpeed))") }
                } else {
                    parts.append(Format.speed(item.speed))
                }
            }
        }
        return parts.joined(separator: " · ")
    }

    /// The menu bar's shorter version: the percentage, plus the time left while converting.
    var compactDetail: String {
        if item.seeding == true { return "↑ \(Format.speed(item.uploadSpeed))" }
        guard !silent else { return "" }
        if case .converting(_, let eta?) = item.mediaPhase, item.state != .paused {
            return [percent, Format.duration(eta)].compactMap { $0 }.joined(separator: " · ")
        }
        if item.mediaPhase == .merging || item.mediaPhase == .processing { return "" }
        return percent ?? ""
    }
}

/// The stage name on a tinted background.
struct StageChip: View {
    let text: String
    let status: ProgressStatus
    var compact = false

    var body: some View {
        Text(text)
            .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
            .foregroundStyle(status.ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 1 : 2)
            .background(status.color.opacity(0.12), in: .rect(cornerRadius: compact ? 5 : 6))
    }
}

/// A 3 pt progress bar in the stage's color.
struct ThinBar: View {
    let status: ProgressStatus

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.anchorTrack)
                Capsule().fill(status.color.opacity(status.dimmed ? 0.4 : 1))
                    .frame(width: proxy.size.width * status.fraction)
            }
        }
        .frame(height: 3)
        .animation(.linear(duration: 0.4), value: status.fraction)
    }
}

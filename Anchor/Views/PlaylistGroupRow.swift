import SwiftUI

/// A playlist's videos folded into one row: name, combined progress and size, one pause/resume for all of them.
/// Expanding it lists the videos as ordinary rows underneath.
struct PlaylistGroupRow: View {
    @Environment(DownloadStore.self) private var store
    let group: PlaylistGroup
    @Binding var isSelected: Bool
    @Binding var isExpanded: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            SelectionCheckbox(isOn: $isSelected, label: "Select all videos in \(group.title)")
                .padding(.horizontal, -4)
            actionButton
            HStack(spacing: 5) {
                Image(systemName: "square.stack.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FileCategory.video.color)
                    .frame(width: 22, height: 22)
                    .padding(.trailing, 4)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(group.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.anchorText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(group.items.count) videos")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.anchorMuted)
                            .fixedSize()
                        Spacer(minLength: 4)
                        Text(group.sizeText)
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Color.anchorMuted2)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    statusLine
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.anchorMuted)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 18)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(isSelected ? Color.anchorAccentWash : hovering ? Color.anchorCard : .clear, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.anchorAccentEdge : .clear, lineWidth: 1))
        .contentShape(.rect(cornerRadius: 8))
        .onTapGesture { withAnimation(.snappy(duration: 0.22)) { isExpanded.toggle() } }
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(group.title), playlist, \(group.detail)")
        .accessibilityAction(named: isExpanded ? "Collapse" : "Expand") { isExpanded.toggle() }
    }

    /// The same stage chip, bar and detail as a single download, for the playlist as a whole.
    @ViewBuilder private var statusLine: some View {
        HStack(spacing: 8) {
            if let stage = group.stage {
                Text(stage)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(color.opacity(0.12), in: .rect(cornerRadius: 5))
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.anchorTrack)
                        Capsule().fill(color).frame(width: proxy.size.width * group.fraction)
                    }
                }
                .frame(height: 3)
                .animation(.linear(duration: 0.4), value: group.fraction)
            } else {
                Spacer(minLength: 0)
            }
            Text(group.detail)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Color.anchorMuted2)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(height: 16)
    }

    private var color: Color {
        switch group.stage {
        case "Downloading": .anchorAccent
        case "Failed": .anchorDanger
        case "Paused": .anchorIdle
        default: .anchorQueued
        }
    }

    private var ink: Color {
        switch group.stage {
        case "Downloading": .anchorAccentInk
        case "Failed": .anchorDanger
        case "Paused": .anchorIdleInk
        default: .anchorMuted2
        }
    }

    @ViewBuilder private var actionButton: some View {
        if group.allDone {
            RevealButton(size: 26, outlined: true) { revealFolder() }
        } else if group.anyRunning {
            IconButton(symbol: "pause.fill", label: "Pause all videos in \(group.title)", tint: color,
                       fill: color.opacity(0.12), size: 26, glyphScale: 0.45) { pauseAll() }
        } else {
            IconButton(symbol: "play.fill", label: "Resume all videos in \(group.title)", tint: color,
                       fill: color.opacity(0.12), size: 26, glyphScale: 0.45) { resumeAll() }
        }
    }

    @ViewBuilder private var menu: some View {
        Button(isExpanded ? "Collapse" : "Show Videos") { isExpanded.toggle() }
        Button("Show in Finder") { revealFolder() }
        Divider()
        if group.anyRunning {
            Button("Pause All") { pauseAll() }
        }
        if group.items.contains(where: { !$0.state.isFinished && !($0.state.isActive || $0.state == .queued) }) {
            Button("Resume All") { resumeAll() }
        }
        Divider()
        Button("Select All Videos") { isSelected = true }
    }

    private func pauseAll() {
        for item in group.items where item.state.isActive || item.state == .queued { store.pause(item.id) }
    }

    private func resumeAll() {
        for item in group.items where !item.state.isFinished {
            if item.state.isFailed { store.retry(item.id) } else { store.resume(item.id) }
        }
    }

    private func revealFolder() {
        guard let folder = group.folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

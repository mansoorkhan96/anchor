import SwiftUI

/// Torrent contents with per-file skip/include (pause/resume icon) and priority, used before and during a download.
struct TorrentFileList: View {
    let files: [TorrentFile]
    var showProgress = false
    var maxHeight: CGFloat = 240
    let onInclude: (_ index: Int, _ included: Bool) -> Void
    let onPriority: (_ index: Int, _ priority: Priority) -> Void
    let onAll: (_ included: Bool) -> Void

    private var included: [TorrentFile] { files.filter(\.included) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Files")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.driftText)
                Text("\(included.count) of \(files.count) · \(Format.bytes(included.reduce(0) { $0 + $1.length }))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Color.driftMuted)
                Spacer()
                Button("Select all") { onAll(true) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.driftAccentInk)
                    .disabled(included.count == files.count)
                Button("Select none") { onAll(false) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.driftAccentInk)
                    .disabled(included.count <= 1)
                    .help("Skips every file except the first; a torrent needs at least one")
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(files) { file in
                        FileRow(file: file, showProgress: showProgress, isLast: file.id == files.last?.id,
                                canSkip: included.count > 1,
                                onInclude: { onInclude(file.index, $0) },
                                onPriority: { onPriority(file.index, $0) })
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: files.count <= 6)
            .background(Color.driftCard, in: .rect(cornerRadius: 12))
        }
    }
}

private struct FileRow: View {
    let file: TorrentFile
    let showProgress: Bool
    let isLast: Bool
    let canSkip: Bool
    let onInclude: (Bool) -> Void
    let onPriority: (Priority) -> Void

    var body: some View {
        HStack(spacing: 10) {
            FileCheckbox(isOn: file.included, label: "Download \(file.name)") { onInclude(!file.included) }
                .disabled(file.included && !canSkip)
                .help(file.included && !canSkip ? "A torrent needs at least one file" : file.included ? "Skip this file" : "Download this file")

            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(file.included ? Color.driftText : Color.driftMuted)
                    .strikethrough(!file.included, color: .driftMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                let folder = (file.path as NSString).deletingLastPathComponent
                if !folder.isEmpty {
                    Text(folder)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.driftMuted)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(Format.bytes(file.length))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Color.driftMuted2)
                .frame(width: 70, alignment: .trailing)

            if showProgress {
                HStack(spacing: 8) {
                    ProgressLine(fraction: file.progress,
                                 color: file.isDone ? .driftSuccess : file.included ? .driftTorrent : .driftTrack, height: 5)
                        .frame(width: 90)
                    Text(file.included ? "\(Int(file.progress * 100))%" : "Skipped")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Color.driftMuted)
                        .frame(width: 46, alignment: .trailing)
                }
            }

            PriorityMenu(priority: file.priority, onChange: onPriority)
                .opacity(file.included ? 1 : 0.4)
                .disabled(!file.included)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(Color.driftLine).frame(height: 1).padding(.leading, 44) }
        }
    }
}

/// Square checkbox for including a torrent file (checked = download it).
private struct FileCheckbox: View {
    let isOn: Bool
    let label: String
    let toggle: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: toggle) {
            RoundedRectangle(cornerRadius: 5)
                .fill(isOn ? Color.driftAccent : Color.driftWindow)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(isOn ? Color.clear : Color.driftText.opacity(0.28), lineWidth: 1.5))
                .overlay {
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 18, height: 18)
                .opacity(isEnabled ? 1 : 0.55)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .allowsWindowActivationEvents(true)
        .accessibilityRepresentation { Toggle(label, isOn: .constant(isOn)) }
    }
}

/// One-click High / Normal / Low control (three small arrow buttons), FDM style. No menu, so it also works in
/// the floating New Download window, where pop-up menus don't deliver their choice.
struct PriorityMenu: View {
    let priority: Priority
    let onChange: (Priority) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Priority.allCases.reversed()) { option in
                let on = option == priority
                Button {
                    onChange(option)
                } label: {
                    Image(systemName: option.symbol)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(on ? (option == .high ? Color.driftAccentInk : Color.driftText) : Color.driftMuted)
                        .frame(width: 24, height: 20)
                        .background(on ? Color.driftWindow : .clear, in: .rect(cornerRadius: 5))
                        .shadow(color: .black.opacity(on ? 0.08 : 0), radius: 1, y: 1)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("\(option.title) priority")
                .accessibilityLabel("\(option.title) priority")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.driftField, in: .rect(cornerRadius: 7))
    }
}

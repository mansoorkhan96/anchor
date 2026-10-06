import SwiftUI

struct MenuBarView: View {
    @Environment(DownloadStore.self) private var store
    @Environment(CleanupStore.self) private var cleanup
    @Environment(\.openWindow) private var openWindow

    private var anyRunning: Bool { store.activeCount + store.queuedCount > 0 }
    private var canResume: Bool { store.items.contains { $0.state == .paused || $0.state.isFailed } }

    var body: some View {
        @Bindable var settings = store.settings
        let recent = store.recentItems(order: settings.menuBarOrder, limit: settings.menuBarCount)
        VStack(alignment: .leading, spacing: 14) {
            header
            if cleanup.attentionBytes > 0 {
                CleanupLine(bytes: cleanup.attentionBytes)
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
                MenuButton(title: "Open Drift", symbol: "macwindow") { showMain() }
                MenuButton(title: "Quit", symbol: "power", shortcut: "⌘Q", muted: true) { NSApp.terminate(nil) }
            }
            .padding(.top, 10)
            .overlay(alignment: .top) { Rectangle().fill(Color.driftLine).frame(height: 1) }
        }
        .padding(16)
        .frame(width: 480)
        .background(Color.driftWindow)
    }

    /// "Drift" and a one-tap icon button that pauses everything, or resumes everything when paused.
    private var header: some View {
        HStack(alignment: .center) {
            Text("Drift")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.driftText)
            Spacer()
            if anyRunning {
                IconButton(symbol: "pause.fill", label: "Pause all downloads", fill: .driftField, size: 30, outlined: true,
                           glyphScale: 0.33) { store.pauseAll() }
            } else if canResume {
                IconButton(symbol: "play.fill", label: "Resume all paused downloads", tint: .white,
                           fill: .driftAccentStrong, size: 30, glyphScale: 0.33) { store.resumeAll() }
            }
        }
        .padding(.horizontal, 4)
    }

    private func showMain() {
        openWindow(id: "main")
        NSApp.activate()
        AppRouter.shared.closeMenuBarPanel()
    }
}

/// "4.2 GB ready for cleanup ›": opens the main window on the Cleanup list.
private struct CleanupLine: View {
    let bytes: Int64
    @State private var hovering = false

    var body: some View {
        Button {
            AppRouter.shared.showCleanup()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.driftSuccess)
                Text("\(Format.bytes(bytes)) ready for cleanup")
                    .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.driftText)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.driftMuted)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(hovering ? Color.driftField : Color.driftCard, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Review downloads you may not need")
    }
}

/// Compact segmented control: light track, white selected pill with a soft shadow.
private struct OrderTabs: View {
    @Binding var selection: MenuBarOrder
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            tab(.newest, title: "Newest", symbol: "clock")
            tab(.unfinishedFirst, title: "Unfinished", symbol: "arrow.down.circle")
        }
        .padding(2)
        .background(Color.driftField, in: .rect(cornerRadius: 8))
    }

    private func tab(_ order: MenuBarOrder, title: String, symbol: String) -> some View {
        let on = selection == order
        return Button {
            withAnimation(.snappy(duration: 0.2)) { selection = order }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
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
            StatusPie(item: item)
            Text(item.fileName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.driftText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(sizeText)
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.driftMuted2)
                .lineLimit(1)
                .fixedSize()
            action
            DeleteButton(label: "Delete \(item.fileName)", makeMenu: deleteMenu)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .background(hovering ? Color.driftField : .clear, in: .rect(cornerRadius: 9))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { AppRouter.shared.showDetails(item.id) }
        .help("Show details for \(item.fileName)")
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
            RevealButton(size: 26) { store.reveal(item.id) }
        }
    }

    /// Same choices as Delete in the main window; a menu works inside the menu bar popover where a dialog can't.
    private func deleteMenu() -> NSMenu {
        let menu = NSMenu()
        let store = store, id = item.id
        menu.addItem(ActionMenuItem("Move Files to Trash") { store.remove([id], deleteFiles: true) })
        menu.addItem(ActionMenuItem("Remove from List Only") { store.remove([id], deleteFiles: false) })
        return menu
    }

    /// "43.2 of 225 MB" while unfinished, the full size once done.
    private var sizeText: String {
        if item.state.isFinished { return Format.bytes(item.totalBytes ?? item.receivedBytes) }
        guard let total = item.totalBytes, total > 0 else { return Format.bytes(item.receivedBytes) }
        return Format.progress(item.receivedBytes, of: total)
    }
}

/// Trash icon that turns red on hover and opens the delete choices.
private struct DeleteButton: View {
    let label: String
    let makeMenu: () -> NSMenu
    @State private var hovering = false

    var body: some View {
        IconButton(symbol: "trash", label: label, tint: hovering ? .driftDanger : .driftMuted2,
                   fill: hovering ? .driftDangerWash : .driftText.opacity(0.07), size: 26) {}
            .overlay(TrailingMenu(makeMenu: makeMenu))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help("Delete")
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

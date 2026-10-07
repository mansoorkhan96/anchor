import SwiftUI

/// "4.2 GB ready for cleanup" above the regular lists. Closing it hides it until the total grows by another 500 MB.
struct CleanupBanner: View {
    @Environment(DownloadStore.self) private var store
    @Environment(CleanupStore.self) private var cleanup

    static func isVisible(cleanup: CleanupStore, settings: AppSettings) -> Bool {
        CleanupRules.showsBanner(total: cleanup.attentionBytes, dismissed: settings.cleanupBannerDismissedBytes)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.driftSuccess)
                .frame(width: 34, height: 34)
                .background(Color.driftSuccessWash, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Format.bytes(cleanup.attentionBytes)) ready for cleanup")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.driftText)
                Text("Old downloads and leftover files you can review. Nothing is removed until you choose to.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.driftMuted)
                    .lineLimit(1)
            }
            Spacer()
            Button("Review") { store.pendingFilter = .cleanup }
                .buttonStyle(.driftPrimary)
            IconButton(symbol: "xmark", label: "Close", tint: .driftMuted, fill: .clear, size: 26, glyphScale: 0.38) {
                store.settings.cleanupBannerDismissedBytes = cleanup.attentionBytes
            }
        }
        .padding(12)
        .background(Color.driftCard, in: .rect(cornerRadius: 14))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Orphaned `.drift-part` files, collapsed to one line until the user reviews them.
struct LeftoversCard: View {
    @Environment(CleanupStore.self) private var cleanup
    @State private var expanded = false
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                CardIcon(symbol: "doc.badge.clock", ink: .driftPausedInk, wash: .driftPaused.opacity(0.18))
                Text("\(Format.bytes(cleanup.leftoverBytes)) of leftover partial files")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.driftText)
                Spacer()
                if expanded {
                    Button("Move to Trash") { confirm = true }
                        .buttonStyle(.driftSecondary)
                }
                Button(expanded ? "Hide" : "Review") {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                }
                .buttonStyle(.driftPlain)
            }
            if expanded {
                VStack(spacing: 4) {
                    ForEach(cleanup.leftovers) { leftover in
                        HStack(spacing: 8) {
                            Text(displayPath(leftover.path))
                                .font(.system(size: 12))
                                .foregroundStyle(Color.driftMuted2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer(minLength: 8)
                            Text(Format.bytes(leftover.bytes))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Color.driftMuted)
                        }
                    }
                }
                .padding(.leading, 46)
            }
        }
        .padding(12)
        .background(Color.driftCard, in: .rect(cornerRadius: 14))
        .confirmationDialog(trashTitle, isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) {
                let paths = Set(cleanup.leftovers.map(\.path))
                Task { await cleanup.trashLeftovers(paths) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("No download in Drift uses these partial files.")
        }
    }

    private var trashTitle: String {
        let count = cleanup.leftovers.count
        return "Move \(count) leftover file\(count == 1 ? "" : "s") (\(Format.bytes(cleanup.leftoverBytes))) to the Trash?"
    }
}

/// Finished downloads whose files are gone; removing them only tidies the list.
struct MissingFilesCard: View {
    @Environment(CleanupStore.self) private var cleanup

    var body: some View {
        let count = cleanup.missing.count
        HStack(spacing: 12) {
            CardIcon(symbol: "questionmark.folder", ink: .driftMuted2, wash: .driftField)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) download\(count == 1 ? "" : "s") whose file\(count == 1 ? " is" : "s are") gone")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.driftText)
                Text("Removing them from the list doesn't touch any files.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.driftMuted)
            }
            Spacer()
            Button("Remove from List") { Task { await cleanup.removeMissing() } }
                .buttonStyle(.driftSecondary)
        }
        .padding(12)
        .background(Color.driftCard, in: .rect(cornerRadius: 14))
    }
}

private struct CardIcon: View {
    let symbol: String
    let ink: Color
    let wash: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(ink)
            .frame(width: 34, height: 34)
            .background(wash, in: .rect(cornerRadius: 10))
    }
}

struct CleanupEmptyState: View {
    @Environment(DownloadStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    let off: Bool
    let searching: Bool

    var body: some View {
        ContentUnavailableView {
            Label(searching ? "No Results" : off ? "Cleanup Is Off" : "Nothing to Clean Up",
                  systemImage: searching ? "magnifyingglass" : "sparkles")
        } description: {
            if searching {
                Text("No suggestions match your search.")
            } else if off {
                Text("Choose which kinds of files to suggest in Settings. Nothing is removed until you choose to.")
            } else {
                Text("Downloads you haven't used for a while show up here.")
            }
        } actions: {
            if off, !searching {
                Button("Open Cleanup Settings") {
                    store.settings.requestedSettingsPage = "cleanup"
                    openSettings()
                }
                .buttonStyle(.driftSecondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

struct ArchiveEmptyState: View {
    let searching: Bool

    var body: some View {
        ContentUnavailableView {
            Label(searching ? "No Results" : "Nothing Archived", systemImage: searching ? "magnifyingglass" : "archivebox")
        } description: {
            Text(searching ? "No archived files match your search."
                 : "Installers whose app you've installed move here, to Downloads/Drift Archive. Restore puts them back.")
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

/// "Archived Oct 6 from Downloads".
func archivedLine(_ item: DownloadItem) -> String? {
    guard let date = item.archivedAt else { return nil }
    let day = date.formatted(.dateTime.month(.abbreviated).day())
    guard let from = item.archivedFrom else { return "Archived \(day)" }
    return "Archived \(day) from \(URL(filePath: from).lastPathComponent)"
}

private func displayPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

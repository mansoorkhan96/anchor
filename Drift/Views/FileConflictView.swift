import SwiftUI

enum FileConflictChoice {
    case rename, overwrite, abort
}

/// FDM-style "file exists already" prompt. Renames automatically when the countdown runs out.
struct FileConflictView: View {
    static let countdown = 50

    let existing: URL
    let renamedTo: String
    let decide: (FileConflictChoice, _ remember: Bool) -> Void

    @State private var remember = false
    @State private var secondsLeft = FileConflictView.countdown

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.driftPausedInk)
                    .frame(width: 38, height: 38)
                    .background(Color.driftPaused.opacity(0.18), in: .rect(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text("File already exists")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.driftText)
                    Text("Choose what to do with the new download.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.driftMuted)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "doc")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.driftMuted)
                    Text(displayPath)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.driftText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Text("Rename saves the new file as \(Text(renamedTo).bold().foregroundStyle(Color.driftText)). Overwrite moves the existing file to the Trash once the download finishes.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.driftMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.driftCard, in: .rect(cornerRadius: 14))

            HStack(spacing: 10) {
                Toggle("Remember my choice", isOn: $remember)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.driftMuted2)
                Spacer()
                Button("Abort") { decide(.abort, false) }
                    .buttonStyle(.driftPlain)
                    .keyboardShortcut(.cancelAction)
                Button("Overwrite") { decide(.overwrite, remember) }
                    .buttonStyle(.driftSecondary)
                Button("Rename (\(secondsLeft))") { decide(.rename, remember) }
                    .buttonStyle(.driftPrimary)
                    .keyboardShortcut(.defaultAction)
                    .monospacedDigit()
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(Color.driftWindow)
        .tint(.driftAccent)
        .task {
            while secondsLeft > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                secondsLeft -= 1
            }
            decide(.rename, remember)
        }
    }

    private var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = existing.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

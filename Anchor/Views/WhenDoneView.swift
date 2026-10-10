import SwiftUI

/// Countdown shown when every download has finished and a "when done" action is set.
struct WhenDoneView: View {
    static let seconds = 30

    let action: WhenDoneAction
    let finish: (_ confirmed: Bool) -> Void
    @State private var left = WhenDoneView.seconds

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: action.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.anchorAccent)
                    .frame(width: 38, height: 38)
                    .background(Color.anchorAccentWash, in: .rect(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text("All downloads finished")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.anchorText)
                    Text(message)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Color.anchorMuted)
                }
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { finish(false) }
                    .buttonStyle(.anchorSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("\(action.title) Now") { finish(true) }
                    .buttonStyle(.anchorPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
        .background(Color.anchorWindow)
        .task {
            while left > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                left -= 1
            }
            finish(true)
        }
    }

    private var message: String {
        switch action {
        case .quit: "Anchor will quit in \(left)s."
        case .sleep: "Your Mac will sleep in \(left)s."
        case .shutDown: "Your Mac will shut down in \(left)s."
        case .nothing: ""
        }
    }
}

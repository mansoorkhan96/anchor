import SwiftUI

/// The New Download window's card for a video link: thumbnail, editable title and what yt-dlp found,
/// or the state of the video tools while they are missing.
struct MediaCard: View {
    @Binding var fileName: String
    let result: MediaProbeResult?
    let probing: Bool
    let quality: MediaQuality
    private var tools: ToolManager { .shared }

    var body: some View {
        HStack(spacing: 14) {
            thumbnail
            VStack(alignment: .leading, spacing: 8) {
                TextField("Title", text: $fileName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.anchorText)
                    .disabled(result == nil)
                HStack(spacing: 6) { chips }
                    .frame(height: 20)
            }
        }
        .padding(14)
        .background(Color.anchorCard, in: .rect(cornerRadius: 14))
    }

    @ViewBuilder private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        Group {
            if let url = result?.thumbnail {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.anchorField
                }
            } else {
                Image(systemName: quality.isAudio ? "music.note" : "film")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(quality.category.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.anchorField)
            }
        }
        .frame(width: 82, height: 46)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.anchorLine))
    }

    @ViewBuilder private var chips: some View {
        if !tools.isReady {
            if tools.isInstalling || !tools.refreshed {
                ProgressView().controlSize(.mini)
                Text(tools.isInstalling ? "Installing video tools…" : "Checking video tools…")
                    .font(.system(size: 11)).foregroundStyle(Color.anchorMuted)
            } else {
                Chip(text: "Video tools needed", ink: .anchorAccentInk, wash: .anchorAccentWash)
                Button("Install all") { tools.installAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.anchorAccentInk)
            }
        } else if probing {
            ProgressView().controlSize(.mini)
            Text("Checking video…").font(.system(size: 11)).foregroundStyle(Color.anchorMuted)
        } else if let result {
            if let site = result.extractorKey ?? result.extractor {
                Chip(text: site, ink: .anchorSuccess, wash: .anchorSuccessWash)
            }
            if let duration = result.duration, duration > 0 {
                Chip(text: Self.clock(duration), ink: .anchorText.opacity(0.8))
            }
            if let uploader = result.uploader, !uploader.isEmpty {
                Chip(text: uploader, ink: .anchorText.opacity(0.8))
            }
            if let size = result.estimatedSize(quality) {
                Chip(text: "About \(Format.bytes(size))", ink: .anchorText.opacity(0.8))
            }
        }
    }

    /// 19 s is "0:19", 3725 s is "1:02:05".
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

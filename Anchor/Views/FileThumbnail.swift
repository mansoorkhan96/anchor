import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Finder-style preview shown before a download's name: a Quick Look thumbnail once the file is on disk
/// (photos, PDFs, videos), otherwise the system icon for its file type.
struct FileThumbnail: View {
    let item: DownloadItem
    var size: CGFloat = 22
    @State private var preview: NSImage?

    var body: some View {
        Image(nsImage: preview ?? Thumbnails.icon(for: item))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .clipShape(.rect(cornerRadius: 3))
            .frame(width: size, height: size)
            .task(id: "\(item.destination.path)|\(item.state.isFinished)") {
                preview = item.state.isFinished ? await Thumbnails.preview(of: item.destination, size: size) : nil
            }
    }
}

@MainActor
enum Thumbnails {
    private static let previews = NSCache<NSString, NSImage>()
    private static var icons: [String: NSImage] = [:]

    static func icon(for item: DownloadItem) -> NSImage {
        let type: UTType
        if item.kind == .torrent, (item.files?.count ?? 0) > 1 {
            type = .folder
        } else {
            type = UTType(filenameExtension: (item.fileName as NSString).pathExtension) ?? .data
        }
        if let icon = icons[type.identifier] { return icon }
        let icon = NSWorkspace.shared.icon(for: type)
        icons[type.identifier] = icon
        return icon
    }

    /// Nil when the file is gone or Quick Look has nothing for it.
    static func preview(of url: URL, size: CGFloat) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)|\(size)" as NSString
        if let cached = previews.object(forKey: key) { return cached }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .all)
        guard let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        else { return nil }
        previews.setObject(image, forKey: key)
        return image
    }
}

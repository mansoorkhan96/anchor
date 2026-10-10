#if DEBUG
import AppKit
import SwiftUI
import notify

/// Debug builds only: `notifyutil -p dev.mansoor.Drift.snapshot` renders every visible window to
/// /tmp/drift-snapshots/<title>.png, so UI can be checked without Screen Recording permission.
enum DebugSnapshot {
    static func install() {
        var token: Int32 = 0
        notify_register_dispatch("dev.mansoor.Drift.snapshot", &token, .main) { _ in
            MainActor.assumeIsolated { capture() }
        }
    }

    /// Renders the custom SwiftUI components with live data (window capture can't see SwiftUI's Metal layers).
    @MainActor static func renderComponents(to dir: URL) {
        let store = DownloadStore.shared
        for scheme in [ColorScheme.dark, .light] {
            let view = VStack(spacing: 14) {
                ThroughputCard()
                VStack(spacing: 6) {
                    ForEach(store.items(for: .all)) { item in
                        DownloadRow(item: item, isSelected: .constant(item.state == .paused))
                    }
                }
            }
            .padding(20)
            .frame(width: 940)
            .background(scheme == .dark ? Color(hex: 0x1C1D21) : .white)
            .environment(store)
            .environment(\.colorScheme, scheme)
            .tint(.anchorAccent)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.cgImage {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: dir.appending(path: "components-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    @MainActor static func capture() {
        let dir = URL(filePath: "/tmp/drift-snapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        renderComponents(to: dir)
        NSLog("DriftSnapshot: \(NSApp.windows.map { "\($0.title)|\($0.isVisible)|\(type(of: $0))" })")
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView, let layer = view.layer else { continue }
            let scale = window.backingScaleFactor
            let size = view.bounds.size
            guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.scaleBy(x: scale, y: scale)
            if !layer.isGeometryFlipped && view.isFlipped {
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: 1, y: -1)
            }
            ctx.setFillColor(window.backgroundColor.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            layer.render(in: ctx)
            guard let image = ctx.makeImage() else { continue }
            let name = window.title.isEmpty ? "window-\(index)" : window.title
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(name).png"))
        }
    }
}
#endif

import AppKit
import SwiftUI

/// Floating panels that appear above every app.
///
/// macOS won't let a background app activate itself (it bounces the Dock icon instead), but a
/// non-activating panel can still come to the front and take keyboard focus while the browser stays active.
@MainActor
enum FloatingPanels {
    private static var open: [NSPanel] = []

    /// Shows `content` in a new floating panel. The content receives a `close` action; Escape calls `onEscape`.
    static func present<Content: View>(onEscape: (() -> Void)? = nil,
                                       @ViewBuilder content: (_ close: @escaping () -> Void) -> Content) {
        let panel = FloatingPanel()
        let close = { [weak panel] in
            guard let panel else { return }
            panel.close()
            open.removeAll { $0 === panel }
        }
        let host = NSHostingController(rootView: content(close).environment(DownloadStore.shared))
        host.sizingOptions = .preferredContentSize
        panel.contentViewController = host
        panel.onCancel = { onEscape?() ?? close() }

        // Stack extra panels slightly so several stay visible.
        let offset = CGFloat(open.count) * 24
        panel.layoutIfNeeded()
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let size = panel.frame.size
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2 + offset,
                                         y: visible.midY - size.height / 2 + visible.height * 0.12 - offset))
        }
        open.append(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
    }
}

@MainActor
final class AddDownloadPanel {
    static let shared = AddDownloadPanel()

    func show(_ request: AddRequest) {
        FloatingPanels.present { close in
            AddDownloadSheet(request: request, onClose: close)
        }
    }
}

private final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
                   styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        animationBehavior = .alertPanel
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

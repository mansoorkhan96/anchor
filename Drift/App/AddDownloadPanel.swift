import AppKit
import SwiftUI

/// Shows "New Download" as a floating panel above every app, FDM style.
///
/// macOS won't let a background app activate itself (it bounces the Dock icon instead), but a
/// non-activating panel can still come to the front and take keyboard focus while the browser stays active.
@MainActor
final class AddDownloadPanel {
    static let shared = AddDownloadPanel()

    private var panels: [NSPanel] = []

    func show(_ request: AddRequest) {
        let panel = FloatingPanel()
        let close = { [weak self, weak panel] in
            guard let panel else { return }
            panel.close()
            self?.panels.removeAll { $0 === panel }
        }
        let root = AddDownloadSheet(request: request, onClose: close)
            .environment(DownloadStore.shared)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = .preferredContentSize
        panel.contentViewController = host
        panel.onCancel = close

        // Stack extra panels slightly so several browser downloads stay visible.
        let offset = CGFloat(panels.count) * 24
        panel.layoutIfNeeded()
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let size = panel.frame.size
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2 + offset,
                                         y: visible.midY - size.height / 2 + visible.height * 0.12 - offset))
        }
        panels.append(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
    }
}

private final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 580, height: 440),
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

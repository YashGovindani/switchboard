import AppKit

/// Spotlight-style floating panel: borderless, non-activating, appears over
/// everything (including fullscreen apps), dismisses on Escape or losing key.
final class OverlayPanel: NSPanel {
    init(contentView: NSView, size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        self.contentView = contentView
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }

    /// Center horizontally, slightly above vertical center (like Spotlight).
    func showCentered() {
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let origin = NSPoint(
                x: frame.midX - self.frame.width / 2,
                y: frame.midY - self.frame.height / 2 + frame.height * 0.12
            )
            setFrameOrigin(origin)
        }
        makeKeyAndOrderFront(nil)
    }
}

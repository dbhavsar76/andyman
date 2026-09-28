import AppKit

/// Borderless, non-activating panel shown under the status item.
///
/// Non-activating means opening it doesn't steal focus from the user's editor or terminal,
/// but it can still become key so text fields and keyboard navigation work.
final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?
    /// Panel-wide shortcuts (⌘1–3, ⌘,), tried after the focused view's own.
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        // The glass draws its own edge; a window shadow would trace the rectangular frame.
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    /// Tab or Shift-Tab (true), before normal key view navigation; return true to consume it.
    var onTab: ((_ backward: Bool) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 48,
           onTab?(event.modifierFlags.contains(.shift)) == true {
            return
        }
        super.sendEvent(event)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        super.performKeyEquivalent(with: event) || onKeyEquivalent?(event) == true
    }

    /// Escape closes the panel.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// With no first responder the window receives key events itself; handle Escape here too.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}

import AppKit
import SwiftUI

/// Owns the floating panel: showing it under the status item and dismissing it when the
/// user clicks elsewhere.
///
/// The window itself never resizes. It's a fixed, transparent canvas as tall as the screen
/// allows, and SwiftUI draws the glass around top-aligned content. Height changes (switching
/// tabs, pushing pages) are then plain SwiftUI animations, which stay in sync frame by frame;
/// resizing an `NSWindow` to follow SwiftUI content can't, and flickers. Clicks on the
/// transparent part fall through to whatever is behind.
final class PanelController {
    let state = PanelState()
    var onVisibilityChange: ((Bool) -> Void)?

    /// The status item's button, used to position the panel beneath it.
    weak var anchorButton: NSStatusBarButton?

    private let model: AppModel
    private let panel = FloatingPanel()
    private var outsideClickMonitor: Any?
    private var appActivationObserver: NSObjectProtocol?
    private var firstResponderObservation: NSKeyValueObservation?
    /// Keyboard focus before a confirmation card opened, restored when it closes.
    private weak var focusBeforeConfirmation: NSView?
    /// Logical open state; the window stays on screen briefly while fading out.
    private var isOpen = false
    /// When the panel was last closed. The page you were on (and anything half-filled on it)
    /// survives closing, so you can look something up and come back; after this long it
    /// starts fresh from the tabs instead.
    private var closedAt: Date?
    private static var navigationResetDelay: TimeInterval {
        #if DEBUG
        // Development aid: `-AMDebugNavigationResetSeconds 5` to test the reset quickly.
        let override = UserDefaults.standard.double(forKey: "AMDebugNavigationResetSeconds")
        if override > 0 { return override }
        #endif
        return 5 * 60
    }

    private static let gapBelowMenuBar: CGFloat = 6
    private static let screenMargin: CGFloat = 8

    init(model: AppModel) {
        self.model = model
        state.closePanel = { [weak self] in self?.close() }
        state.setPanelBehindDialogs = { [weak self] behind in
            self?.panel.level = behind ? .floating : .statusBar
        }

        let hostingView = NSHostingView(
            rootView: PanelRootView()
                .environment(model)
                .environment(state)
        )
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.onCancel = { [weak self] in
            guard let self else { return }
            // Esc dismisses an open confirmation first, then the panel.
            if state.confirmation != nil { state.resolveConfirmation(false) } else { close() }
        }
        panel.onKeyEquivalent = { [weak self] event in self?.handleShortcut(event) ?? false }
        trapFocusInConfirmations()
        firstResponderObservation = panel.observe(\.firstResponder, options: [.new]) { [weak self] panel, _ in
            // SwiftUI frames its focus proxy after making it first responder; read it next turn.
            DispatchQueue.main.async { self?.revealFirstResponder(in: panel) }
        }
    }

    /// Keyboard focus moved: if it's on a control in the scrolling content, scroll it into view.
    /// SwiftUI gives the focused control a stand-in first responder (a proxy view in the scroll
    /// view's clip view) framed like the control; header controls sit outside the scroll view.
    private func revealFirstResponder(in window: NSWindow) {
        guard let view = window.firstResponder as? NSView,
              let document = view.enclosingScrollView?.documentView,
              view !== document
        else { return }
        var rect = view.convert(view.bounds, to: document)
        if !document.isFlipped { rect.origin.y = document.bounds.height - rect.maxY }
        state.focusMoved(to: rect)
    }

    /// While a confirmation card is open, Tab stays on its buttons; when it closes, focus goes
    /// back to the control that opened it (Cancel), or the one after it (confirmed: the control
    /// usually turns into a spinner or disappears).
    private func trapFocusInConfirmations() {
        panel.onTab = { [weak self] _ in
            guard let self, state.confirmation != nil else { return false }
            state.moveConfirmationFocus()
            return true
        }
        state.onConfirmationOpened = { [weak self] in
            self?.focusBeforeConfirmation = self?.panel.firstResponder as? NSView
        }
        state.onConfirmationClosed = { [weak self] confirmed in
            guard let self, let previous = focusBeforeConfirmation else { return }
            focusBeforeConfirmation = nil
            // After the card's fade-out, once its buttons have left the key view loop.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, isOpen, previous.window === panel else { return }
                if confirmed {
                    panel.selectKeyView(following: previous)
                } else {
                    panel.makeFirstResponder(previous)
                }
            }
        }
    }

    /// ⌘1–3 switch tabs (from any page), ⌘, opens Settings, ⌘R refreshes.
    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              state.confirmation == nil,
              let key = event.charactersIgnoringModifiers
        else { return false }
        switch key {
        case "1", "2", "3":
            let tabs = PanelTab.allCases
            guard let index = Int(key), index <= tabs.count else { return false }
            state.showTab(tabs[index - 1])
        case ",":
            if state.pages.last != .settings { state.push(.settings) }
        case "r":
            Task { await model.refresh() }
        default:
            return false
        }
        return true
    }

    var isVisible: Bool { isOpen }

    func toggle() {
        isVisible ? close() : show()
    }

    func show() {
        guard !isOpen else { return }
        isOpen = true
        if let closedAt, Date().timeIntervalSince(closedAt) > Self.navigationResetDelay {
            state.popToRoot()
        }
        closedAt = nil

        let frame = canvasFrame()
        state.maxHeight = frame.height - 2 * PanelMetrics.shadowMargin
        panel.setFrame(frame, display: false)

        if !panel.isVisible { panel.alphaValue = 0 }
        panel.makeKeyAndOrderFront(nil)
        // Don't start with a focus ring on whichever control happens to be first.
        panel.makeFirstResponder(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        startMonitoringOutsideInteraction()
        onVisibilityChange?(true)
        Task { await model.refresh() }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        closedAt = Date()
        state.resolveConfirmation(false)
        stopMonitoringOutsideInteraction()
        onVisibilityChange?(false)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Reopened while fading out: leave it on screen.
                guard let self, !self.isOpen else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    /// The fixed window frame: centred under the status item, clamped to the screen, reaching
    /// down to the bottom of the visible area. Includes a margin so the glass's shadow isn't clipped.
    private func canvasFrame() -> NSRect {
        let margin = PanelMetrics.shadowMargin
        let width = PanelMetrics.width + 2 * margin
        let screen = anchorButton?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var top = visible.maxY - Self.gapBelowMenuBar
        var midX = visible.midX
        if let button = anchorButton, let buttonWindow = button.window {
            let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            top = buttonFrame.minY - Self.gapBelowMenuBar
            midX = buttonFrame.midX
        }
        #if DEBUG
        // Development aid: `-AMDebugPanelOffset 160` opens the panel this far below the menu
        // bar (for screenshots with room around it).
        top -= CGFloat(UserDefaults.standard.double(forKey: "AMDebugPanelOffset"))
        #endif

        let x = min(
            max(midX - width / 2, visible.minX + Self.screenMargin - margin),
            visible.maxX - width - Self.screenMargin + margin
        )
        // The glass starts `margin` below the window's top edge; shift up so it sits under the menu bar.
        let windowTop = top + margin
        let height = min(windowTop - visible.minY, PanelMetrics.maxHeight + 2 * margin)
        return NSRect(x: x, y: windowTop - height, width: width, height: height)
    }

    // MARK: - Dismissal

    private func startMonitoringOutsideInteraction() {
        // Global monitors only see events destined for other apps, i.e. clicks outside us,
        // including clicks that fall through the transparent part of the panel.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissUnlessPinned() }
        }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let isSelf = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            MainActor.assumeIsolated {
                if !isSelf { self?.dismissUnlessPinned() }
            }
        }
    }

    private func stopMonitoringOutsideInteraction() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let appActivationObserver { NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver) }
        outsideClickMonitor = nil
        appActivationObserver = nil
    }

    private func dismissUnlessPinned() {
        if !state.isPinned { close() }
    }
}

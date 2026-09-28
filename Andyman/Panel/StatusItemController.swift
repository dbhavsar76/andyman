import AndroidKit
import AppKit
import Observation

/// The menu bar icon. Left click toggles the panel; right click (or control-click) shows a
/// menu to start or stop devices directly, plus Settings and Quit.
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panelController: PanelController
    private let model: AppModel

    init(panelController: PanelController, model: AppModel) {
        self.panelController = panelController
        self.model = model
        super.init()

        guard let button = statusItem.button else { return }
        button.image = MenuBarIcon.image(running: false)
        // Shrink rather than clip if a menu bar is ever shorter than the icon.
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "Andyman"
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        panelController.anchorButton = button
        panelController.onVisibilityChange = { [weak button] visible in
            // The button resets its highlight when its own click tracking ends, which happens
            // after our action runs; set it on the next turn of the run loop so it sticks.
            DispatchQueue.main.async { button?.highlight(visible) }
        }
        observeRunningEmulators()
    }

    /// Shows a progress ring on the icon while packages install, or a dot while emulators run.
    private func observeRunningEmulators() {
        let (running, progress) = withObservationTracking {
            (model.emulators.runningCount, model.setup.progress ?? model.sdk.installProgress)
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeRunningEmulators() }
        }
        // Quantize so the icon only redraws when the ring visibly changes.
        let step = progress.map { (($0 * 20).rounded() / 20) }
        statusItem.button?.image = MenuBarIcon.image(running: running > 0, progress: step)
        var tooltip = switch running {
        case 0: "Andyman"
        case 1: "Andyman: 1 emulator running"
        default: "Andyman: \(running) emulators running"
        }
        if let progress {
            tooltip += model.setup.isRunning ? "\nSetting up Android development (\(Int(progress * 100))%)" : "\nInstalling SDK packages (\(Int(progress * 100))%)"
        }
        statusItem.button?.toolTip = tooltip
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if wantsMenu {
            panelController.close()
            showMenu(from: sender)
        } else {
            panelController.toggle()
        }
    }

    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        let store = model.emulators

        if !store.devices.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(title: "Virtual Devices"))
            for device in store.devices {
                let item = NSMenuItem(title: device.displayName, action: #selector(toggleDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device.name
                item.image = NSImage(systemSymbolName: device.formFactor.symbolName, accessibilityDescription: nil)
                switch store.state(of: device) {
                case .running, .booting:
                    item.state = .on
                    item.toolTip = "Click to stop"
                case .starting, .stopping:
                    item.state = .mixed
                    item.isEnabled = false
                case .unavailable:
                    item.isEnabled = false
                case .stopped:
                    item.toolTip = "Click to start"
                }
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Andyman", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 6), in: button)
    }

    @objc private func toggleDevice(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String, let device = model.emulators.device(named: name) else { return }
        model.emulators.toggle(device)
    }

    @objc private func openSettings() {
        panelController.state.popToRoot()
        panelController.state.push(.settings)
        panelController.show()
    }
}

/// Menu bar glyph: the app icon's "A" (two legs over a translucent layer) as a template
/// image, with a small dot cut into the corner while emulators run.
enum MenuBarIcon {
    /// The glyph's size, matching SF Symbols at menu bar size.
    private static let glyphSize = NSSize(width: 18, height: 18)

    /// - Parameter progress: install progress (0…1) drawn as a ring in the corner; takes
    ///   precedence over the running dot.
    static func image(running: Bool, progress: Double? = nil) -> NSImage {
        if let progress {
            return progressImage(progress: progress)
        }
        guard running else {
            let image = NSImage(size: glyphSize, flipped: false) { rect in
                drawGlyph(in: rect)
                return true
            }
            image.isTemplate = true
            image.accessibilityDescription = "Andyman"
            return image
        }

        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            drawGlyph(in: NSRect(x: (rect.width - glyphSize.width) / 2 - 1, y: 0, width: glyphSize.width, height: glyphSize.height))
            let dot = NSRect(x: rect.maxX - 8, y: 1, width: 7, height: 7)
            // Punch a ring out of the glyph so the dot reads clearly at menu bar size.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Andyman, emulators running"
        return image
    }

    /// Draws the "A" into an 18×18 point rect: the translucent layer, then the right leg, then
    /// the left leg on top, each cut out of what's beneath it by a thin gap.
    private static func drawGlyph(in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        let thickness: CGFloat = 3.2, halfWidth: CGFloat = 7.8, top: CGFloat = 16.5, bottom: CGFloat = 1.5
        let gap: CGFloat = 0.9
        let r = thickness / 2
        let apex = CGPoint(x: 9, y: top - r)
        let bottomLeft = CGPoint(x: 9 - halfWidth + r, y: bottom + r)
        let bottomRight = CGPoint(x: 9 + halfWidth - r, y: bottom + r)
        let height = top - bottom

        context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        context.addPath(roundedTriangle([
            CGPoint(x: 9, y: top - 0.39 * height),
            CGPoint(x: 9 + 0.57 * halfWidth, y: bottom + 0.1),
            CGPoint(x: 9 - 0.57 * halfWidth, y: bottom + 0.1),
        ], radius: 0.6))
        context.fillPath()

        context.setFillColor(NSColor.black.cgColor)
        for (start, end) in [(apex, bottomRight), (bottomLeft, apex)] {
            context.setBlendMode(.clear)
            context.addPath(capsule(from: start, to: end, radius: r + gap))
            context.fillPath()
            context.setBlendMode(.normal)
            context.addPath(capsule(from: start, to: end, radius: r))
            context.fillPath()
        }
        context.restoreGState()
    }

    /// A bar with round ends whose end caps are centred on `start` and `end`.
    private static func capsule(from start: CGPoint, to end: CGPoint, radius: CGFloat) -> CGPath {
        let length = hypot(end.x - start.x, end.y - start.y)
        var transform = CGAffineTransform(translationX: start.x, y: start.y).rotated(by: atan2(end.y - start.y, end.x - start.x))
        let bar = CGRect(x: -radius, y: -radius, width: length + 2 * radius, height: 2 * radius)
        return CGPath(roundedRect: bar, cornerWidth: radius, cornerHeight: radius, transform: &transform)
    }

    private static func roundedTriangle(_ points: [CGPoint], radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2))
        for i in 1...3 {
            path.addArc(tangent1End: points[i % 3], tangent2End: points[(i + 1) % 3], radius: radius)
        }
        path.closeSubpath()
        return path
    }

    private static func progressImage(progress: Double) -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            drawGlyph(in: NSRect(x: (rect.width - glyphSize.width) / 2 - 2, y: 0, width: glyphSize.width, height: glyphSize.height))
            let ring = NSRect(x: rect.maxX - 10, y: 0.5, width: 9, height: 9)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: ring.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            // Faint full ring, then the completed arc clockwise from 12 o'clock.
            let track = NSBezierPath(ovalIn: ring.insetBy(dx: 1, dy: 1))
            track.lineWidth = 2
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            let center = NSPoint(x: ring.midX, y: ring.midY)
            arc.appendArc(withCenter: center, radius: ring.width / 2 - 1, startAngle: 90, endAngle: 90 - 360 * max(0.04, progress), clockwise: true)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Andyman, installing packages"
        return image
    }
}

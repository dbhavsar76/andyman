import AndroidKit
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum PanelTab: String, CaseIterable, Identifiable {
    case emulators, sdk, tools

    var id: Self { self }

    var title: String {
        switch self {
        case .emulators: "Emulators"
        case .sdk: "SDK"
        case .tools: "Tools"
        }
    }
}

/// Pages pushed on top of the tabs (drill-down navigation inside the panel).
enum PanelPage: Hashable {
    case settings
    /// Details for the AVD with this name.
    case emulator(String)
    case editEmulator(String)
    /// "New Virtual Device" flow: pick a profile, then a system image, then settings.
    case newDeviceProfile
    case newDeviceImage
    case newDeviceSettings
    case sdkCategory(PackageCategory)
    /// Review licenses for the pending install (`SDKStore.licenseRequest`).
    case sdkLicenses
    case setup
    /// Review licenses setup needs (`SetupStore.pendingLicenses`).
    case setupLicenses
    /// Project doctor for the React Native project at this path.
    case project(String)
    /// "Free Up Space".
    case cleanup
    /// Command-line tool and agent skill.
    case agents
}

/// Navigation and window-level state the SwiftUI content reads and drives.
@Observable
final class PanelState {
    enum Direction { case forward, backward }

    var tab: PanelTab = .emulators
    private(set) var pages: [PanelPage] = []
    /// Which way the last navigation went, so pages slide in from the matching side.
    private(set) var direction: Direction = .forward
    /// Tallest the panel may get on the current screen; content scrolls beyond this.
    var maxHeight: CGFloat = PanelMetrics.maxHeight

    struct Confirmation: Identifiable {
        let id = UUID()
        var message: String
        var detail: String
        var confirmTitle: String
        var destructive: Bool
        var action: () -> Void
    }

    /// Where keyboard focus just moved, in the scrolling content's coordinates, so the panel
    /// can scroll it into view (see `FocusScrolling`).
    struct FocusedArea: Equatable {
        var rect: CGRect
        var serial: Int
    }

    private(set) var focusedArea: FocusedArea?

    func focusMoved(to rect: CGRect) {
        focusedArea = FocusedArea(rect: rect, serial: (focusedArea?.serial ?? 0) + 1)
    }

    /// The confirmation card's button with keyboard focus. The card keeps focus to itself:
    /// Tab and Shift-Tab move between its two buttons (see `moveConfirmationFocus`).
    enum ConfirmationButton { case cancel, confirm }
    var confirmationFocus: ConfirmationButton = .cancel
    /// Called when a confirmation opens (false) or closes (true, with whether it was confirmed),
    /// so the panel can put keyboard focus back where it was.
    @ObservationIgnored var onConfirmationClosed: ((_ confirmed: Bool) -> Void)?
    @ObservationIgnored var onConfirmationOpened: (() -> Void)?

    func moveConfirmationFocus() {
        confirmationFocus = confirmationFocus == .cancel ? .confirm : .cancel
    }

    /// A pending in-panel confirmation (see `confirm`).
    private(set) var confirmation: Confirmation?

    /// While pinned (a file picker is open), clicking elsewhere doesn't close the panel.
    private(set) var pinCount = 0
    var isPinned: Bool { pinCount > 0 }

    @ObservationIgnored var closePanel: () -> Void = {}
    /// Lowers (true) or restores (false) the panel's window level, so modal dialogs appear above it.
    @ObservationIgnored var setPanelBehindDialogs: (Bool) -> Void = { _ in }

    func push(_ page: PanelPage) {
        navigate(.forward) { $0.append(page) }
    }

    func pop() {
        navigate(.backward) { _ = $0.popLast() }
    }

    /// Replaces the whole stack, e.g. to land on a new device's details after creating it.
    func show(_ stack: [PanelPage]) {
        navigate(.forward) { $0 = stack }
    }

    /// Sets the direction first, then changes pages on the next turn of the run loop: the
    /// outgoing page's transition is read from its last render, so it has to see the new
    /// direction before it's removed.
    private func navigate(_ direction: Direction, _ change: @escaping (inout [PanelPage]) -> Void) {
        self.direction = direction
        DispatchQueue.main.async {
            withAnimation(PanelMetrics.navigationAnimation) { change(&self.pages) }
        }
    }

    /// Goes back to the tabs, on `tab`.
    func showTab(_ tab: PanelTab) {
        if pages.isEmpty {
            withAnimation(PanelMetrics.navigationAnimation) { self.tab = tab }
        } else {
            self.tab = tab
            navigate(.backward) { $0 = [] }
        }
    }

    /// Resets navigation without animating (used while the panel is hidden).
    func popToRoot() { pages.removeAll() }

    func pin() { pinCount += 1 }
    func unpin() { pinCount = max(0, pinCount - 1) }

    /// Runs a modal dialog with the panel kept open and moved below it. `runModal` puts its
    /// window at the modal level, under our status-bar-level panel, so the panel steps down.
    private func runDialog<T>(_ body: () -> T) -> T {
        pin()
        setPanelBehindDialogs(true)
        defer {
            setPanelBehindDialogs(false)
            unpin()
        }
        NSApp.activate()
        return body()
    }

    /// Asks for confirmation with a card inside the panel. The panel is already key, so
    /// Return confirms and Esc cancels (a system alert from a menu bar app often can't take
    /// keyboard focus, so keys would go to whatever app was in front).
    func confirm(
        _ message: String,
        detail: String,
        confirmTitle: String,
        destructive: Bool = false,
        onConfirm: @escaping () -> Void
    ) {
        onConfirmationOpened?()
        // Cancel first, so Space can't confirm something destructive by accident (Return
        // still confirms).
        confirmationFocus = .cancel
        withAnimation(.snappy(duration: 0.2)) {
            confirmation = Confirmation(message: message, detail: detail, confirmTitle: confirmTitle, destructive: destructive, action: onConfirm)
        }
    }

    func resolveConfirmation(_ confirmed: Bool) {
        guard let confirmation else { return }
        withAnimation(.snappy(duration: 0.2)) { self.confirmation = nil }
        if confirmed { confirmation.action() }
        onConfirmationClosed?(confirmed)
    }

    /// Shows a folder picker above the panel, keeping the panel open meanwhile.
    func chooseFolder(title: String, startingAt path: String?) -> URL? {
        runDialog { runFolderPicker(title: title, startingAt: path) }
    }

    /// Shows a file picker above the panel, keeping the panel open meanwhile.
    func chooseFile(title: String, prompt: String, allowedExtensions: [String]) -> URL? {
        runDialog {
            let openPanel = NSOpenPanel()
            openPanel.title = title
            openPanel.prompt = prompt
            openPanel.canChooseDirectories = false
            openPanel.canChooseFiles = true
            openPanel.allowsMultipleSelection = false
            openPanel.allowedContentTypes = allowedExtensions.compactMap { UTType(filenameExtension: $0) }
            return openPanel.runModal() == .OK ? openPanel.url : nil
        }
    }

    private func runFolderPicker(title: String, startingAt path: String?) -> URL? {
        let openPanel = NSOpenPanel()
        openPanel.title = title
        openPanel.prompt = "Choose"
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.canCreateDirectories = true
        openPanel.showsHiddenFiles = false
        if let path { openPanel.directoryURL = URL(fileURLWithPath: path) }

        return openPanel.runModal() == .OK ? openPanel.url : nil
    }
}

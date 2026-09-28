import AndroidKit
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var panelController: PanelController?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeEditMenu()
        let panelController = PanelController(model: model)
        self.panelController = panelController
        statusItemController = StatusItemController(panelController: panelController, model: model)

        Notifier.shared.isPanelVisible = { [weak panelController] in panelController?.isVisible ?? false }
        Notifier.shared.open = { [weak panelController] destination in
            guard let panelController else { return }
            if !panelController.isVisible { panelController.state.popToRoot() }
            switch destination {
            case .emulators: panelController.state.tab = .emulators
            case .sdk: panelController.state.tab = .sdk
            case .tools: panelController.state.tab = .tools
            case .setup:
                panelController.state.tab = .tools
                panelController.state.show([.setup])
            }
            panelController.show()
        }
        Notifier.shared.start()
        GlobalHotKey.shared.action = { [weak panelController] in panelController?.toggle() }
        GlobalHotKey.shared.start()

        Task {
            await model.refresh()
            offerSetupOnFirstLaunch(panelController)
        }

        #if DEBUG
        // Development aid: `-AMDebugNotify` posts a test notification (the panel is closed).
        if UserDefaults.standard.bool(forKey: "AMDebugNotify") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Notifier.shared.post("Test notification", "Notifications from Andyman are working.", opening: .emulators)
            }
        }
        // Development aid: `-AMDebugOpenPanel tools` opens the panel on a tab at launch.
        if let tab = UserDefaults.standard.string(forKey: "AMDebugOpenPanel") {
            panelController.state.tab = PanelTab(rawValue: tab) ?? .emulators
            if tab == "settings" { panelController.state.push(.settings) }
            if tab == "cleanup" { panelController.state.tab = .tools; panelController.state.push(.cleanup) }
            // `-AMDebugOpenPanel edit -AMDebugDevice <avd>`: details, then the edit page after 2 s.
            if tab == "edit", let device = UserDefaults.standard.string(forKey: "AMDebugDevice") {
                panelController.state.push(.emulator(device))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { panelController.state.push(.editEmulator(device)) }
            }
            if tab == "agents" { panelController.state.tab = .tools; panelController.state.push(.agents) }
            if tab == "setup" { panelController.state.tab = .tools; panelController.state.push(.setup) }
            // `-AMDebugOpenPanel project -AMDebugProject <path>` opens the project doctor.
            if tab == "project", let path = UserDefaults.standard.string(forKey: "AMDebugProject") {
                panelController.state.tab = .tools
                panelController.state.push(.project(path))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { panelController.show() }
        }
        #endif
    }

    /// The first time the app runs on a Mac without an Android SDK, open straight to setup.
    private func offerSetupOnFirstLaunch(_ panelController: PanelController) {
        let key = "didOfferSetup"
        guard model.report?.sdk.inventory == nil, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        panelController.state.show([.setup])
        panelController.show()
    }

    /// A menu bar app has no visible main menu, but text fields still need one: ⌘A, ⌘C, ⌘V,
    /// ⌘X and ⌘Z are dispatched through its key equivalents. It's never shown.
    private static func makeEditMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Andyman", action: nil, keyEquivalent: ""))
        menu.addItem(editItem)
        return menu
    }
}

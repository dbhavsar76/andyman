import AppKit

/// AppKit entry point. The app is menu-bar only (`LSUIElement`), so there are no SwiftUI
/// scenes: the status item and panel are managed by `AppDelegate`.
@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

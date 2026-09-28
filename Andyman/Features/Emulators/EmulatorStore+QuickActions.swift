import AndroidKit
import AppKit

/// React Native helpers on running emulators: dev menu, reload, Metro port, screenshots, APKs.
extension EmulatorStore {
    struct Notice: Equatable {
        var message: String
        /// A file to reveal (a screenshot).
        var file: URL?
    }

    enum QuickAction {
        case devMenu, reload, screenshot
        case reverse(port: Int)
        case install(URL)

        var progressTitle: String {
            switch self {
            case .devMenu: "Opening developer menu…"
            case .reload: "Reloading…"
            case .screenshot: "Taking screenshot…"
            case let .reverse(port): "Forwarding port \(port)…"
            case let .install(apk): "Installing \(apk.lastPathComponent)…"
            }
        }
    }

    func run(_ action: QuickAction, on device: VirtualDevice) {
        guard let sdkRoot = catalog?.sdkRoot, let instance = instance(of: device) else { return }
        let actions = EmulatorActions(sdkRoot: sdkRoot, serial: instance.serial)
        failure = nil
        actionsInProgress[device.name] = action.progressTitle
        Task {
            defer { actionsInProgress[device.name] = nil }
            do {
                switch action {
                case .devMenu:
                    try await actions.openDevMenu()
                case .reload:
                    try await actions.reloadApp()
                case let .reverse(port):
                    try await actions.reverse(port: port)
                    show(Notice(message: "\(device.displayName) reaches this Mac's port \(port) as localhost:\(port)."))
                case .screenshot:
                    let destination = EmulatorActions.defaultScreenshotURL(deviceName: device.displayName)
                    try await actions.screenshot(to: destination)
                    NSSound(named: "Grab")?.play()
                    show(Notice(message: "Saved \(destination.lastPathComponent)", file: destination))
                case let .install(apk):
                    try await actions.install(apk: apk)
                    show(Notice(message: "Installed \(apk.lastPathComponent) on \(device.displayName)."))
                }
            } catch {
                failure = Failure(message: error.localizedDescription)
            }
        }
    }

    func show(_ notice: Notice) {
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self.notice = nil
        }
    }

    /// Whether files dropped on a device row can be installed (APKs only).
    static func apks(in urls: [URL]) -> [URL] {
        urls.filter { $0.pathExtension.lowercased() == "apk" }
    }
}

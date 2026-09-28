import AndroidKit
import AppKit
import Observation

/// Live state of the user's virtual devices and running emulators.
@Observable
final class EmulatorStore {
    enum DeviceState: Equatable {
        case stopped
        case starting
        case booting
        case running
        case stopping
        case unavailable(String)

        var isActive: Bool {
            switch self {
            case .starting, .booting, .running, .stopping: true
            case .stopped, .unavailable: false
            }
        }
    }

    struct Failure: Equatable {
        var message: String
        var logPath: String?
    }

    private(set) var devices: [VirtualDevice] = []
    private(set) var issues: [AVDIssue] = []
    private(set) var running: [RunningEmulator] = []
    private(set) var hasLoaded = false
    private(set) var diskUsage: [String: Int64] = [:]
    private(set) var profiles: [DeviceProfile] = []
    var draft = NewDeviceDraft()
    var failure: Failure?
    /// A short-lived success message, e.g. after a screenshot (see `EmulatorStore+QuickActions`).
    var notice: Notice?
    /// Quick actions in progress, by AVD name ("Installing app.apk…").
    var actionsInProgress: [String: String] = [:]
    @ObservationIgnored var noticeTask: Task<Void, Never>?

    /// Devices we've asked to start or stop and are waiting on.
    private var pending: [String: DeviceState] = [:]
    private var booted: Set<String> = []

    private(set) var catalog: AVDCatalog?
    private var controller: EmulatorController?
    private var environment: [String: String] = [:]
    private var java: JavaInstallation?
    private var cmdlineTools: URL?
    private var watchers: [DirectoryWatcher] = []
    private var pollTask: Task<Void, Never>?
    private var reloadScheduled = false

    var runningCount: Int { running.count }

    // MARK: - Setup

    /// Points the store at the current SDK and environment. Cheap to call repeatedly.
    func configure(sdk: SDKLocation?, inventory: SDKInventory?, java: JavaInstallation?, environment: [String: String]) {
        let avdDirectory = AVDCatalog.defaultDirectory(environment: environment)
        let sdkRoot = sdk?.url
        self.environment = environment
        self.java = java
        let tools = inventory?.sdkmanagerPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent() }
        if tools != cmdlineTools {
            cmdlineTools = tools
            profiles = []
            // Load in the background now, so opening "New Virtual Device" doesn't wait (or
            // swap its whole content in mid-transition).
            Task { await loadProfiles() }
        }
        let changed = catalog?.directory != avdDirectory || catalog?.sdkRoot != sdkRoot
        guard changed || catalog == nil else { return }

        catalog = AVDCatalog(directory: avdDirectory, sdkRoot: sdkRoot)
        controller = sdkRoot.map { EmulatorController(sdkRoot: $0, avdDirectory: avdDirectory) }
        watchers = [
            DirectoryWatcher(url: avdDirectory) { [weak self] in self?.scheduleReload() },
            DirectoryWatcher(url: RunningEmulators.discoveryDirectory) { [weak self] in self?.scheduleReload() },
        ]
        scheduleReload()
    }

    func scheduleReloadSoon() { scheduleReload() }

    /// Coalesces bursts of file-system events into one reload.
    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            reloadScheduled = false
            await reload()
        }
    }

    func reload() async {
        guard let catalog else { return }
        let (scan, running) = await Task.detached {
            (catalog.scan(), RunningEmulators.scan())
        }.value

        devices = scan.devices
        issues = scan.issues
        let vanished = self.running.filter { old in !running.contains { $0.pid == old.pid } }
        self.running = running
        for emulator in vanished where pending[emulator.avdName] != .stopping {
            notifyIfCrashed(emulator)
        }
        hasLoaded = true

        let runningNames = Set(running.map(\.avdName))
        booted.formIntersection(runningNames)
        // Resolve pending transitions the file system has caught up with.
        for (name, state) in pending {
            switch state {
            case .starting where runningNames.contains(name): pending[name] = .booting
            case .stopping where !runningNames.contains(name): pending[name] = nil
            default: break
            }
        }
        updatePolling()
    }

    // MARK: - State

    func state(of device: VirtualDevice) -> DeviceState {
        if let pending = pending[device.name] { return pending }
        if instance(of: device) != nil {
            return booted.contains(device.name) ? .running : .booting
        }
        if let problem = device.problems.first {
            switch problem {
            case .systemImageMissing: return .unavailable("System image not installed")
            case .configMissing: return .unavailable("Configuration missing")
            }
        }
        return .stopped
    }

    func instance(of device: VirtualDevice) -> RunningEmulator? {
        RunningEmulators.instance(of: device, in: running)
    }

    func device(named name: String) -> VirtualDevice? {
        devices.first { $0.name == name }
    }

    // MARK: - Actions

    func start(_ device: VirtualDevice, options: EmulatorLaunchOptions = .init()) {
        guard let controller else {
            failure = Failure(message: "No Android SDK found. Choose one in Settings.")
            return
        }
        failure = nil
        pending[device.name] = .starting
        Notifier.shared.requestAuthorization()
        do {
            let pid = try controller.start(device, options: options, environment: environment)
            Task {
                do {
                    _ = try await controller.waitUntilRunning(device, launcherPID: pid)
                    await reload()
                } catch {
                    pending[device.name] = nil
                    report(error, device: device)
                }
            }
        } catch {
            pending[device.name] = nil
            report(error, device: device)
        }
    }

    func stop(_ device: VirtualDevice, force: Bool = false) {
        guard let controller, let instance = instance(of: device) else { return }
        failure = nil
        pending[device.name] = .stopping
        Task {
            try? await controller.stop(instance, force: force)
            await reload()
            // If it somehow survived, stop showing a spinner forever.
            if self.instance(of: device) != nil { pending[device.name] = nil }
        }
    }

    func toggle(_ device: VirtualDevice) {
        switch state(of: device) {
        case .stopped: start(device)
        case .booting, .running: stop(device)
        case .starting, .stopping, .unavailable: break
        }
    }

    func wipeData(_ device: VirtualDevice) {
        perform(device) { try $0.wipeData(device) }
    }

    func delete(_ device: VirtualDevice) {
        perform(device) { try $0.delete(device) }
    }

    func fix(_ issue: AVDIssue) {
        guard let catalog else { return }
        do {
            try catalog.fix(issue)
        } catch {
            failure = Failure(message: error.localizedDescription)
        }
        scheduleReload()
    }

    func showInFinder(_ device: VirtualDevice) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: device.path)])
    }

    func openLog(_ device: VirtualDevice) {
        let log = EmulatorController.logFile(for: device.name)
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.open(log)
        } else {
            failure = Failure(message: "\(device.displayName) hasn't been started from Andyman yet, so there's no log.")
        }
    }

    func hasLog(_ device: VirtualDevice) -> Bool {
        FileManager.default.fileExists(atPath: EmulatorController.logFile(for: device.name).path)
    }

    func loadDiskUsage(for device: VirtualDevice) async {
        let bytes = await Task.detached { AVDCatalog.diskUsage(of: device) }.value
        diskUsage[device.name] = bytes
    }

    private func perform(_ device: VirtualDevice, _ action: (AVDCatalog) throws -> Void) {
        guard let catalog else { return }
        failure = nil
        do {
            try action(catalog)
        } catch {
            report(error, device: device)
        }
        diskUsage[device.name] = nil
        scheduleReload()
    }

    private func report(_ error: any Error, device: VirtualDevice) {
        var logPath: String?
        if case let EmulatorError.exitedDuringStartup(_, path) = error { logPath = path }
        failure = Failure(message: error.localizedDescription, logPath: logPath)
        Notifier.shared.post("\(device.displayName) couldn't start", error.localizedDescription, opening: .emulators)
    }

    /// Checks a moment later, so an emulator that's exiting normally has time to remove its
    /// discovery file.
    private func notifyIfCrashed(_ emulator: RunningEmulator) {
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard RunningEmulators.exitedUncleanly(emulator) else { return }
            Notifier.shared.post("\(displayName(emulator.avdName)) quit unexpectedly", "Open Andyman to see the emulator's log.", opening: .emulators)
        }
    }

    private func displayName(_ avdName: String) -> String {
        device(named: avdName)?.displayName ?? avdName.replacingOccurrences(of: "_", with: " ")
    }

    // MARK: - Polling

    /// While anything is booting or running, check boot state and whether processes are still
    /// alive (a crashed emulator leaves its discovery file behind, so no file event fires).
    private func updatePolling() {
        let needsPolling = !running.isEmpty || !pending.isEmpty
        if needsPolling, pollTask == nil {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1.5))
                    await self?.poll()
                }
            }
        } else if !needsPolling {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private func poll() async {
        guard let controller else { return }
        let current = await Task.detached { RunningEmulators.scan() }.value
        if current != running {
            await reload()
            return
        }
        for emulator in running where !booted.contains(emulator.avdName) {
            if await controller.isBooted(emulator) {
                booted.insert(emulator.avdName)
                if pending[emulator.avdName] == .booting {
                    pending[emulator.avdName] = nil
                    Notifier.shared.post("\(displayName(emulator.avdName)) is ready", "The emulator finished booting.", opening: .emulators)
                }
            }
        }
    }
}

// MARK: - Creating and editing

extension EmulatorStore {
    var canCreate: Bool { catalog?.sdkRoot != nil && cmdlineTools != nil }

    /// Loads device profiles once per command-line tools install.
    func loadProfiles() async {
        guard profiles.isEmpty, let sdkRoot = catalog?.sdkRoot else { return }
        let tools = cmdlineTools
        let environment = environment
        profiles = await DeviceProfiles.load(sdkRoot: sdkRoot, cmdlineTools: tools, environment: environment)
    }

    func installedImages() -> [SystemImage] {
        guard let sdkRoot = catalog?.sdkRoot else { return [] }
        return SystemImages.installed(in: sdkRoot)
    }

    func suggestedName(profile: DeviceProfile, image: SystemImage) -> String {
        catalog?.suggestedName(profile: profile, image: image) ?? AVDCatalog.sanitizedName("\(profile.name) API \(image.apiLevel)")
    }

    /// Starts a fresh create flow.
    func beginNewDevice() {
        draft = NewDeviceDraft()
    }

    func create(_ spec: AVDSpec) async throws -> VirtualDevice {
        guard let catalog else { throw AVDEditError.toolsMissing }
        let java = java
        let environment = environment
        let device = try await catalog.create(spec, java: java, environment: environment)
        await reload()
        return device
    }

    func settings(of device: VirtualDevice) -> AVDSettings {
        catalog?.settings(of: device) ?? AVDSettings()
    }

    /// Saves edits; renames first if the AVD name changed. Returns the (possibly renamed) device.
    func save(_ device: VirtualDevice, name: String, settings: AVDSettings) throws -> VirtualDevice {
        guard let catalog else { throw AVDEditError.toolsMissing }
        var device = device
        if name != device.name {
            device = try catalog.rename(device, to: name)
        }
        device = try catalog.update(device, settings: settings)
        scheduleReloadSoon()
        return device
    }

    func duplicate(_ device: VirtualDevice) throws -> VirtualDevice {
        guard let catalog else { throw AVDEditError.toolsMissing }
        var name = "\(device.name)_Copy"
        var counter = 2
        while self.device(named: name) != nil {
            name = "\(device.name)_Copy_\(counter)"
            counter += 1
        }
        let copy = try catalog.duplicate(device, as: name)
        scheduleReloadSoon()
        return copy
    }

    func snapshots(of device: VirtualDevice) async -> [AVDSnapshot] {
        guard let catalog else { return [] }
        return await Task.detached { catalog.snapshots(of: device) }.value
    }

    func deleteSnapshot(_ snapshot: AVDSnapshot, of device: VirtualDevice) {
        guard let catalog else { return }
        do {
            try catalog.deleteSnapshot(snapshot, of: device)
        } catch {
            failure = Failure(message: error.localizedDescription)
        }
        diskUsage[device.name] = nil
    }
}

/// Choices made so far in the "New Virtual Device" flow.
@Observable
final class NewDeviceDraft {
    var category: VirtualDevice.FormFactor = .phone
    var showLegacy = false
    var profile: DeviceProfile?
    var image: SystemImage?
}

extension EmulatorStore {
    /// Whether the SDK has frame artwork for a profile (Android Studio copies these into `<sdk>/skins`).
    func hasFrame(for profile: DeviceProfile) -> Bool {
        guard let sdkRoot = catalog?.sdkRoot else { return false }
        return FileManager.default.fileExists(atPath: sdkRoot.appending(path: "skins/\(profile.id)").path)
    }
}

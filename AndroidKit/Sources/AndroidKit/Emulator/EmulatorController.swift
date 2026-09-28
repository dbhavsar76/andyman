import Foundation

public struct EmulatorLaunchOptions: Sendable, Equatable, Codable {
    public enum GPUMode: String, Sendable, Codable, CaseIterable {
        case auto, host, swiftshader = "swiftshader_indirect"
    }

    /// Ignore the quick-boot snapshot and boot from scratch.
    public var coldBoot = false
    /// Factory-reset user data before booting.
    public var wipeData = false
    /// Save a quick-boot snapshot on exit (the emulator's default).
    public var saveSnapshot = true
    /// Run without a window (useful for tests and CI).
    public var headless = false
    public var gpu: GPUMode?

    public init(coldBoot: Bool = false, wipeData: Bool = false, saveSnapshot: Bool = true, headless: Bool = false, gpu: GPUMode? = nil) {
        self.coldBoot = coldBoot
        self.wipeData = wipeData
        self.saveSnapshot = saveSnapshot
        self.headless = headless
        self.gpu = gpu
    }

    var arguments: [String] {
        var arguments: [String] = []
        if coldBoot { arguments.append("-no-snapshot-load") }
        if wipeData { arguments.append("-wipe-data") }
        if !saveSnapshot { arguments.append("-no-snapshot-save") }
        if headless { arguments.append("-no-window") }
        if let gpu { arguments += ["-gpu", gpu.rawValue] }
        return arguments
    }
}

public enum EmulatorError: Error, Sendable, Equatable, LocalizedError {
    case emulatorNotInstalled
    case adbNotInstalled
    case cannotLaunch(String, reason: String)
    case alreadyRunning(String)
    case exitedDuringStartup(String, logPath: String)
    case notRunning(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .emulatorNotInstalled: "The Android Emulator isn't installed in this SDK."
        case .adbNotInstalled: "Platform Tools (adb) aren't installed in this SDK."
        case let .cannotLaunch(name, reason): "\(name) can't start: \(reason)"
        case let .alreadyRunning(name): "\(name) is already running."
        case let .exitedDuringStartup(name, logPath): "\(name) quit while starting. See \(logPath)."
        case let .notRunning(name): "\(name) isn't running."
        case let .timedOut(name): "\(name) didn't finish booting in time."
        }
    }
}

/// Starts, watches and stops emulators.
public struct EmulatorController: Sendable {
    public let sdkRoot: URL
    public let avdDirectory: URL
    private let adb: ADB

    public init(sdkRoot: URL, avdDirectory: URL) {
        self.sdkRoot = sdkRoot
        self.avdDirectory = avdDirectory
        adb = ADB(sdkRoot: sdkRoot)
    }

    public var emulatorExecutable: URL { sdkRoot.appending(path: "emulator/emulator") }

    /// Shared by the app and the CLI so "Open Log" finds output from either.
    public static func logFile(for avdName: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/Andyman/Emulators/\(avdName).log")
    }

    /// Launches an emulator detached from the caller. Returns once the process has started;
    /// use `waitUntilRunning` and `waitForBoot` to follow its progress.
    @discardableResult
    public func start(_ device: VirtualDevice, options: EmulatorLaunchOptions = .init(), environment: [String: String]) throws -> pid_t {
        guard FileManager.default.isExecutableFile(atPath: emulatorExecutable.path) else { throw EmulatorError.emulatorNotInstalled }
        if let problem = device.problems.first {
            let reason = switch problem {
            case let .systemImageMissing(package): "its system image (\(package)) isn't installed."
            case .configMissing: "its config.ini is missing."
            }
            throw EmulatorError.cannotLaunch(device.displayName, reason: reason)
        }
        if RunningEmulators.instance(of: device, in: RunningEmulators.scan()) != nil {
            throw EmulatorError.alreadyRunning(device.displayName)
        }

        var environment = environment
        environment["ANDROID_HOME"] = sdkRoot.path
        environment["ANDROID_SDK_ROOT"] = sdkRoot.path
        environment["ANDROID_AVD_HOME"] = avdDirectory.path

        return try DetachedProcess.spawn(
            emulatorExecutable,
            arguments: ["-avd", device.name] + options.arguments,
            environment: environment,
            logFile: Self.logFile(for: device.name),
            currentDirectory: sdkRoot.appending(path: "emulator")
        )
    }

    /// Waits for the emulator to publish its discovery file (a few seconds after launch).
    /// Fails early if the launcher process dies, which usually means a bad config or image.
    public func waitUntilRunning(_ device: VirtualDevice, launcherPID: pid_t, timeout: Duration = .seconds(60)) async throws -> RunningEmulator {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let instance = RunningEmulators.instance(of: device, in: RunningEmulators.scan()) { return instance }
            if !DetachedProcess.isRunning(launcherPID) {
                // The launcher can exit after handing off to qemu; give discovery one more look.
                try await Task.sleep(for: .milliseconds(500))
                if let instance = RunningEmulators.instance(of: device, in: RunningEmulators.scan()) { return instance }
                throw EmulatorError.exitedDuringStartup(device.displayName, logPath: Self.logFile(for: device.name).path)
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        throw EmulatorError.timedOut(device.displayName)
    }

    /// Waits until Android reports `sys.boot_completed=1`.
    public func waitForBoot(_ emulator: RunningEmulator, timeout: Duration = .seconds(180)) async throws {
        guard adb.isInstalled else { throw EmulatorError.adbNotInstalled }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            guard DetachedProcess.isRunning(emulator.pid) else {
                throw EmulatorError.exitedDuringStartup(emulator.avdName, logPath: Self.logFile(for: emulator.avdName).path)
            }
            if await adb.isBootCompleted(emulator.serial) { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw EmulatorError.timedOut(emulator.avdName)
    }

    public func isBooted(_ emulator: RunningEmulator) async -> Bool {
        await adb.isBootCompleted(emulator.serial)
    }

    /// Asks the emulator to shut down cleanly (saving its quick-boot snapshot if enabled),
    /// falling back to SIGTERM if the console doesn't respond. With `force`, kills it outright.
    public func stop(_ emulator: RunningEmulator, force: Bool = false, timeout: Duration = .seconds(20)) async throws {
        if force {
            kill(emulator.pid, SIGKILL)
            return
        }
        if adb.isInstalled {
            _ = try? await adb.emulatorConsole(emulator.serial, ["kill"])
        } else {
            kill(emulator.pid, SIGTERM)
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !DetachedProcess.isRunning(emulator.pid) { return }
            try await Task.sleep(for: .milliseconds(300))
        }
        kill(emulator.pid, SIGTERM)
    }
}

import Foundation

/// Hardware settings users commonly change. `nil` means "leave as is" (or the profile default
/// when creating).
public struct AVDSettings: Sendable, Equatable, Codable {
    public enum Orientation: String, Sendable, Codable, CaseIterable {
        case portrait, landscape
    }

    public var displayName: String?
    public var ramMB: Int?
    public var heapMB: Int?
    /// Internal storage in MB.
    public var storageMB: Int?
    /// SD card size in MB; 0 removes the card.
    public var sdCardMB: Int?
    public var cpuCores: Int?
    public var hardwareKeyboard: Bool?
    public var showFrame: Bool?
    public var orientation: Orientation?
    public var gpu: EmulatorLaunchOptions.GPUMode?

    public init(
        displayName: String? = nil, ramMB: Int? = nil, heapMB: Int? = nil, storageMB: Int? = nil,
        sdCardMB: Int? = nil, cpuCores: Int? = nil, hardwareKeyboard: Bool? = nil, showFrame: Bool? = nil,
        orientation: Orientation? = nil, gpu: EmulatorLaunchOptions.GPUMode? = nil
    ) {
        self.displayName = displayName
        self.ramMB = ramMB
        self.heapMB = heapMB
        self.storageMB = storageMB
        self.sdCardMB = sdCardMB
        self.cpuCores = cpuCores
        self.hardwareKeyboard = hardwareKeyboard
        self.showFrame = showFrame
        self.orientation = orientation
        self.gpu = gpu
    }

    /// Current values read back from an AVD's `config.ini`.
    public init(config: [String: String]) {
        displayName = config["avd.ini.displayname"]
        ramMB = config["hw.ramSize"].flatMap(AVDCatalog.megabytes)
        heapMB = config["vm.heapSize"].flatMap(AVDCatalog.megabytes)
        storageMB = config["disk.dataPartition.size"].flatMap(AVDCatalog.megabytes)
        sdCardMB = config["hw.sdCard"] == "no" ? 0 : config["sdcard.size"].flatMap(AVDCatalog.megabytes)
        cpuCores = config["hw.cpu.ncore"].flatMap { Int($0) }
        hardwareKeyboard = config["hw.keyboard"].map { $0 == "yes" }
        showFrame = config["showDeviceFrame"].map { $0 == "yes" }
        orientation = config["hw.initialOrientation"].flatMap(Orientation.init(rawValue:))
        gpu = config["hw.gpu.mode"].flatMap(EmulatorLaunchOptions.GPUMode.init(rawValue:))
    }
}

public struct AVDSpec: Sendable, Equatable, Codable {
    /// AVD name used with `emulator -avd`: letters, digits, `.`, `_` and `-`.
    public var name: String
    public var profileID: String
    public var systemImage: String
    public var settings: AVDSettings

    public init(name: String, profileID: String, systemImage: String, settings: AVDSettings = .init()) {
        self.name = name
        self.profileID = profileID
        self.systemImage = systemImage
        self.settings = settings
    }
}

public enum AVDEditError: Error, Sendable, Equatable, LocalizedError {
    case invalidName(String)
    case nameTaken(String)
    case javaMissing
    case toolsMissing
    case avdmanagerFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidName(name): "“\(name)” isn't a valid AVD name. Use letters, numbers, dots, dashes and underscores."
        case let .nameTaken(name): "A virtual device named \(name) already exists."
        case .javaMissing: "Creating devices needs a JDK \(JavaLocator.minimumMajorVersion) or newer."
        case .toolsMissing: "Creating devices needs the Android SDK Command-line Tools."
        case let .avdmanagerFailed(message): "avdmanager couldn't create the device: \(message)"
        }
    }
}

extension AVDCatalog {
    /// Suggests a free AVD name from a profile and image, e.g. `Pixel_9_API_36`.
    public func suggestedName(profile: DeviceProfile, image: SystemImage) -> String {
        let base = Self.sanitizedName("\(profile.name) API \(image.apiLevel)")
        var name = base
        var counter = 2
        while FileManager.default.fileExists(atPath: directory.appending(path: "\(name).ini").path) {
            name = "\(base)_\(counter)"
            counter += 1
        }
        return name
    }

    /// Turns a display name into a valid AVD name (`Pixel 9 (Test)` → `Pixel_9_Test`).
    public static func sanitizedName(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var result = ""
        for scalar in text.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else if !result.hasSuffix("_") {
                result += "_"
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name == sanitizedName(name) && !name.hasPrefix(".")
    }

    func validateNewName(_ name: String) throws {
        guard Self.isValidName(name) else { throw AVDEditError.invalidName(name) }
        let taken = FileManager.default.fileExists(atPath: directory.appending(path: "\(name).ini").path)
            || FileManager.default.fileExists(atPath: directory.appending(path: "\(name).avd").path)
        guard !taken else { throw AVDEditError.nameTaken(name) }
    }

    // MARK: - Create

    /// Creates an AVD with `avdmanager`, then applies Android Studio's defaults (GPU on, device
    /// frame, cameras, keyboard) and the requested settings, which `avdmanager` alone doesn't.
    public func create(_ spec: AVDSpec, java: JavaInstallation?, environment: [String: String], runner: ProcessRunner = ProcessRunner()) async throws -> VirtualDevice {
        try validateNewName(spec.name)
        guard let sdkRoot else { throw AVDEditError.toolsMissing }
        guard let avdmanager = SDKInspector.inventory(at: sdkRoot).avdmanagerPath else { throw AVDEditError.toolsMissing }
        guard let java else { throw AVDEditError.javaMissing }

        var environment = environment
        environment["JAVA_HOME"] = java.home
        environment["ANDROID_HOME"] = sdkRoot.path
        environment["ANDROID_SDK_ROOT"] = sdkRoot.path
        environment["ANDROID_AVD_HOME"] = directory.path

        var arguments = ["create", "avd", "--name", spec.name, "--package", spec.systemImage, "--device", spec.profileID]
        let sdCard = spec.settings.sdCardMB ?? 512
        if sdCard > 0 { arguments += ["--sdcard", "\(sdCard)M"] }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try await runner.run(
            URL(fileURLWithPath: avdmanager),
            arguments: arguments,
            environment: environment,
            standardInput: Data("no\n".utf8), // "Do you wish to create a custom hardware profile?"
            timeout: .seconds(90)
        )
        guard result.succeeded else {
            let output = (result.stderrString + "\n" + result.stdoutString)
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("Error:") }
                .map { String($0.dropFirst("Error:".count)).trimmingCharacters(in: .whitespaces) }
            throw AVDEditError.avdmanagerFailed(output ?? "exit code \(result.exitCode)")
        }

        let folder = directory.appending(path: "\(spec.name).avd", directoryHint: .isDirectory)
        try applyStudioDefaults(folder: folder, name: spec.name, sdkRoot: sdkRoot, sdCardMB: sdCard)
        try writeINI(name: spec.name, folder: folder)
        let device = try device(named: spec.name)
        return try update(device, settings: spec.settings)
    }

    /// The parts of Android Studio's AVD setup that `avdmanager` leaves out.
    private func applyStudioDefaults(folder: URL, name: String, sdkRoot: URL, sdCardMB: Int) throws {
        let configURL = folder.appending(path: "config.ini")
        var config = try ConfigFile(url: configURL)
        config["avd.id"] = nil // "<build>" placeholders
        config["avd.name"] = nil
        config["AvdId"] = name
        config["avd.ini.displayname"] = name.replacingOccurrences(of: "_", with: " ")
        config["hw.gpu.enabled"] = "yes"
        config["hw.gpu.mode"] = "auto"
        config["hw.keyboard"] = "yes"
        config["hw.camera.back"] = "virtualscene"
        config["hw.camera.front"] = "emulated"
        config["hw.sdCard"] = sdCardMB > 0 ? "yes" : "no"
        if sdCardMB > 0 { config["sdcard.size"] = "\(sdCardMB)M" }

        let tags = (config["tag.ids"] ?? config["tag.id"] ?? "").split(separator: ",")
        config["PlayStore.enabled"] = tags.contains { $0.contains("playstore") } ? "true" : "false"

        // Device frame, if the profile has one and the SDK has its artwork.
        if let deviceName = config["hw.device.name"] {
            let skin = sdkRoot.appending(path: "skins/\(deviceName)")
            if FileManager.default.fileExists(atPath: skin.path) {
                config["skin.name"] = deviceName
                config["skin.path"] = skin.path
                config["skin.dynamic"] = "yes"
                config["showDeviceFrame"] = "yes"
            } else {
                config["showDeviceFrame"] = "no"
            }
        }
        try config.write(to: configURL)
    }

    /// Writes `<name>.ini` with both absolute and relative paths (avdmanager omits `path.rel`).
    private func writeINI(name: String, folder: URL) throws {
        let iniURL = directory.appending(path: "\(name).ini")
        var ini = (try? ConfigFile(url: iniURL)) ?? ConfigFile(contents: "avd.ini.encoding=UTF-8")
        let config = PropertiesFile.load(folder.appending(path: "config.ini")) ?? [:]
        ini["path"] = folder.path
        ini["path.rel"] = "\(directory.lastPathComponent)/\(folder.lastPathComponent)"
        if let target = config["target"] { ini["target"] = target }
        try ini.write(to: iniURL)
    }

    // MARK: - Edit

    /// Applies settings to an AVD's `config.ini`. `nil` fields are left unchanged.
    @discardableResult
    public func update(_ device: VirtualDevice, settings: AVDSettings, running: [RunningEmulator] = RunningEmulators.scan()) throws -> VirtualDevice {
        guard RunningEmulators.instance(of: device, in: running) == nil else { throw AVDError.running(device.displayName) }
        let configURL = URL(fileURLWithPath: device.path).appending(path: "config.ini")
        var config = try ConfigFile(url: configURL)

        if let displayName = settings.displayName?.trimmingCharacters(in: .whitespaces), !displayName.isEmpty {
            config["avd.ini.displayname"] = displayName
        }
        if let ram = settings.ramMB { config["hw.ramSize"] = "\(ram)M" }
        if let heap = settings.heapMB { config["vm.heapSize"] = "\(heap)M" }
        if let storage = settings.storageMB { config["disk.dataPartition.size"] = Self.sizeString(megabytes: storage) }
        if let sdCard = settings.sdCardMB {
            config["hw.sdCard"] = sdCard > 0 ? "yes" : "no"
            if sdCard > 0 { config["sdcard.size"] = "\(sdCard)M" }
        }
        if let cores = settings.cpuCores { config["hw.cpu.ncore"] = "\(cores)" }
        if let keyboard = settings.hardwareKeyboard { config["hw.keyboard"] = keyboard ? "yes" : "no" }
        if let showFrame = settings.showFrame { config["showDeviceFrame"] = showFrame && config["skin.path"] != nil ? "yes" : "no" }
        if let orientation = settings.orientation { config["hw.initialOrientation"] = orientation.rawValue }
        if let gpu = settings.gpu { config["hw.gpu.mode"] = gpu.rawValue }

        try config.write(to: configURL)
        return try self.device(named: device.name)
    }

    /// Current editable settings of an AVD.
    public func settings(of device: VirtualDevice) -> AVDSettings {
        AVDSettings(config: PropertiesFile.load(URL(fileURLWithPath: device.path).appending(path: "config.ini")) ?? [:])
    }

    /// `8192` → `8G`, `1536` → `1536M`.
    static func sizeString(megabytes: Int) -> String {
        megabytes % 1024 == 0 ? "\(megabytes / 1024)G" : "\(megabytes)M"
    }

    // MARK: - Rename & duplicate

    /// Renames an AVD's `.ini` (the name used with `emulator -avd`); the folder keeps its name,
    /// as in Android Studio.
    @discardableResult
    public func rename(_ device: VirtualDevice, to newName: String, running: [RunningEmulator] = RunningEmulators.scan()) throws -> VirtualDevice {
        guard newName != device.name else { return device }
        guard RunningEmulators.instance(of: device, in: running) == nil else { throw AVDError.running(device.displayName) }
        guard Self.isValidName(newName) else { throw AVDEditError.invalidName(newName) }
        guard !FileManager.default.fileExists(atPath: directory.appending(path: "\(newName).ini").path) else {
            throw AVDEditError.nameTaken(newName)
        }

        try FileManager.default.moveItem(at: URL(fileURLWithPath: device.iniPath), to: directory.appending(path: "\(newName).ini"))
        let configURL = URL(fileURLWithPath: device.path).appending(path: "config.ini")
        var config = try ConfigFile(url: configURL)
        config["AvdId"] = newName
        try config.write(to: configURL)
        return try self.device(named: newName)
    }

    /// Copies an AVD, including its installed apps and data. Snapshots and lock files aren't
    /// copied, so the copy's first start is a cold boot.
    @discardableResult
    public func duplicate(_ device: VirtualDevice, as newName: String, displayName: String? = nil, running: [RunningEmulator] = RunningEmulators.scan()) throws -> VirtualDevice {
        guard RunningEmulators.instance(of: device, in: running) == nil else { throw AVDError.running(device.displayName) }
        try validateNewName(newName)

        let folder = directory.appending(path: "\(newName).avd", directoryHint: .isDirectory)
        // On APFS this is a copy-on-write clone, so even multi-GB images copy instantly.
        try FileManager.default.copyItem(at: URL(fileURLWithPath: device.path), to: folder)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for entry in entries where entry.hasSuffix(".lock") || entry == "snapshots" || entry == "hardware-qemu.ini" {
            try? FileManager.default.removeItem(at: folder.appending(path: entry))
        }

        let configURL = folder.appending(path: "config.ini")
        var config = try ConfigFile(url: configURL)
        config["AvdId"] = newName
        config["avd.ini.displayname"] = displayName ?? "\(device.displayName) Copy"
        try config.write(to: configURL)
        try writeINI(name: newName, folder: folder)
        return try self.device(named: newName)
    }

    // MARK: - Snapshots

    public func snapshots(of device: VirtualDevice) -> [AVDSnapshot] {
        let folder = URL(fileURLWithPath: device.path).appending(path: "snapshots", directoryHint: .isDirectory)
        return SDKInspector.childDirectories(of: folder).compactMap { directory -> AVDSnapshot? in
            let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey])
            return AVDSnapshot(
                name: directory.lastPathComponent,
                path: directory.path,
                date: values?.contentModificationDate,
                sizeBytes: Self.folderSize(directory)
            )
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Moves a snapshot to the Trash.
    public func deleteSnapshot(_ snapshot: AVDSnapshot, of device: VirtualDevice, running: [RunningEmulator] = RunningEmulators.scan()) throws {
        guard RunningEmulators.instance(of: device, in: running) == nil else { throw AVDError.running(device.displayName) }
        try FileManager.default.trashItem(at: URL(fileURLWithPath: snapshot.path), resultingItemURL: nil)
    }

    /// Disk space used by a folder and everything in it, in bytes.
    public static func folderSize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

public struct AVDSnapshot: Sendable, Equatable, Codable, Identifiable {
    public var name: String
    public var path: String
    public var date: Date?
    public var sizeBytes: Int64

    public var id: String { path }
    /// `default_boot` is the quick-boot snapshot the emulator saves on exit.
    public var isQuickBoot: Bool { name == "default_boot" }
}

import Foundation

/// Something wrong with the AVD folder that we can offer to fix.
public struct AVDIssue: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        /// `<name>.ini` points to a folder that doesn't exist.
        case missingFolder = "missing_folder"
        /// An `.avd` folder that no `.ini` points to, so the emulator can't see it.
        case unregisteredFolder = "unregistered_folder"
    }

    public var kind: Kind
    /// The AVD name (from the `.ini`, or the folder's `AvdId` for unregistered folders).
    public var name: String
    public var iniPath: String?
    public var folderPath: String

    public var id: String { "\(kind.rawValue):\(folderPath)" }

    public var message: String {
        switch kind {
        case .missingFolder: "Its files are missing, so it can't start."
        case .unregisteredFolder: "Its files exist but the emulator can't see it."
        }
    }

    public var fixTitle: String {
        switch kind {
        case .missingFolder: "Remove Entry"
        case .unregisteredFolder: "Restore"
        }
    }
}

public struct AVDScan: Sendable, Equatable, Codable {
    public var directory: String
    public var devices: [VirtualDevice]
    public var issues: [AVDIssue]
}

public enum AVDError: Error, Sendable, Equatable, LocalizedError {
    case notFound(String)
    case running(String)

    public var errorDescription: String? {
        switch self {
        case let .notFound(name): "No virtual device named \(name)."
        case let .running(name): "\(name) is running. Stop it first."
        }
    }
}

/// Reads and manages AVDs directly on disk: no JVM tools, so it's instant.
public struct AVDCatalog: Sendable {
    public let directory: URL
    /// Used to check that each AVD's system image is installed.
    public let sdkRoot: URL?

    public init(directory: URL, sdkRoot: URL?) {
        self.directory = directory
        self.sdkRoot = sdkRoot
    }

    /// Where AVDs live: `ANDROID_AVD_HOME`, then `ANDROID_USER_HOME/avd`,
    /// the legacy `ANDROID_EMULATOR_HOME/avd` and `ANDROID_SDK_HOME/.android/avd`, then `~/.android/avd`.
    public static func defaultDirectory(environment: [String: String]) -> URL {
        func url(_ path: String) -> URL { URL(fileURLWithPath: ShellEnvironment.expandTilde(path), isDirectory: true) }
        if let path = environment["ANDROID_AVD_HOME"], !path.isEmpty { return url(path) }
        if let path = environment["ANDROID_USER_HOME"], !path.isEmpty { return url(path).appending(path: "avd") }
        if let path = environment["ANDROID_EMULATOR_HOME"], !path.isEmpty { return url(path).appending(path: "avd") }
        if let path = environment["ANDROID_SDK_HOME"], !path.isEmpty { return url(path).appending(path: ".android/avd") }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".android/avd", directoryHint: .isDirectory)
    }

    // MARK: - Reading

    public func scan() -> AVDScan {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []

        var devices: [VirtualDevice] = []
        var issues: [AVDIssue] = []
        var referencedFolders = Set<String>()

        for entry in entries where entry.hasSuffix(".ini") {
            let iniURL = directory.appending(path: entry)
            let name = String(entry.dropLast(4))
            let ini = PropertiesFile.load(iniURL) ?? [:]
            guard let folder = resolveFolder(ini) else {
                let expected = ini["path"] ?? directory.appending(path: "\(name).avd").path
                issues.append(AVDIssue(kind: .missingFolder, name: name, iniPath: iniURL.path, folderPath: expected))
                continue
            }
            referencedFolders.insert(folder.standardizedFileURL.path)
            devices.append(device(named: name, iniPath: iniURL.path, folder: folder, target: ini["target"]))
        }

        for entry in entries where entry.hasSuffix(".avd") {
            let folder = directory.appending(path: entry, directoryHint: .isDirectory)
            guard !referencedFolders.contains(folder.standardizedFileURL.path) else { continue }
            let config = PropertiesFile.load(folder.appending(path: "config.ini")) ?? [:]
            let name = config["AvdId"] ?? String(entry.dropLast(4))
            issues.append(AVDIssue(kind: .unregisteredFolder, name: name, iniPath: nil, folderPath: folder.path))
        }

        devices.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        issues.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return AVDScan(directory: directory.path, devices: devices, issues: issues)
    }

    public func device(named name: String) throws -> VirtualDevice {
        guard let device = scan().devices.first(where: { $0.name == name }) else { throw AVDError.notFound(name) }
        return device
    }

    /// Disk space used by an AVD's folder, in bytes.
    public static func diskUsage(of device: VirtualDevice) -> Int64 {
        folderSize(URL(fileURLWithPath: device.path, isDirectory: true))
    }

    /// `path` from the `.ini`, falling back to `path.rel` (relative to the AVD directory's parent)
    /// when the absolute path is stale, e.g. after moving to a new Mac.
    private func resolveFolder(_ ini: [String: String]) -> URL? {
        var candidates: [URL] = []
        if let path = ini["path"] { candidates.append(URL(fileURLWithPath: path, isDirectory: true)) }
        if let relative = ini["path.rel"] {
            candidates.append(directory.deletingLastPathComponent().appending(path: relative, directoryHint: .isDirectory))
        }
        return candidates.first { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    private func device(named name: String, iniPath: String, folder: URL, target: String?) -> VirtualDevice {
        guard let config = PropertiesFile.load(folder.appending(path: "config.ini")) else {
            return VirtualDevice(
                name: name, displayName: name.replacingOccurrences(of: "_", with: " "), path: folder.path, iniPath: iniPath,
                apiLevel: target.flatMap(Self.apiLevel), abi: nil, tagID: nil, tagDisplay: nil, playStore: false,
                deviceName: nil, manufacturer: nil, formFactor: .phone, ramMB: nil, screenWidth: nil, screenHeight: nil,
                screenDensity: nil, dataPartitionSize: nil, systemImagePackage: nil, problems: [.configMissing]
            )
        }

        let sysdir = config["image.sysdir.1"]
        let imagePackage = sysdir.map(Self.packageID(forSysdir:))
        var problems: [VirtualDevice.Problem] = []
        if let sdkRoot, let sysdir, let imagePackage,
           !FileManager.default.fileExists(atPath: sdkRoot.appending(path: sysdir).path) {
            problems.append(.systemImageMissing(package: imagePackage))
        }

        let tagIDs = (config["tag.ids"] ?? config["tag.id"] ?? "").split(separator: ",").map(String.init)
        return VirtualDevice(
            name: name,
            displayName: nonEmpty(config["avd.ini.displayname"]) ?? name.replacingOccurrences(of: "_", with: " "),
            path: folder.path,
            iniPath: iniPath,
            apiLevel: (target ?? config["target"]).flatMap(Self.apiLevel),
            abi: config["abi.type"],
            tagID: config["tag.id"],
            tagDisplay: config["tag.display"],
            playStore: config["PlayStore.enabled"]?.lowercased() == "true" || tagIDs.contains("google_apis_playstore"),
            deviceName: config["hw.device.name"],
            manufacturer: config["hw.device.manufacturer"],
            formFactor: Self.formFactor(config: config, tagIDs: tagIDs),
            ramMB: config["hw.ramSize"].flatMap(Self.megabytes),
            screenWidth: config["hw.lcd.width"].flatMap { Int($0) },
            screenHeight: config["hw.lcd.height"].flatMap { Int($0) },
            screenDensity: config["hw.lcd.density"].flatMap { Int($0) },
            dataPartitionSize: config["disk.dataPartition.size"],
            systemImagePackage: imagePackage,
            problems: problems
        )
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Parsing helpers

    /// `android-37.1` → `37.1`; `Google Inc.:Google APIs:23` → `23`.
    static func apiLevel(fromTarget target: String) -> String? {
        let last = target.split(separator: ":").last.map(String.init) ?? target
        let value = last.hasPrefix("android-") ? String(last.dropFirst("android-".count)) : last
        return value.first?.isNumber == true ? value : nil
    }

    /// `system-images/android-36/google_apis/arm64-v8a/` → `system-images;android-36;google_apis;arm64-v8a`.
    static func packageID(forSysdir sysdir: String) -> String {
        sysdir.split(separator: "/").joined(separator: ";")
    }

    /// Parses sizes like `2048`, `2048M`, `2G` or `512 MB` into megabytes.
    public static func megabytes(_ value: String) -> Int? {
        let lower = value.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "b", with: "")
        if lower.hasSuffix("g"), let number = Double(lower.dropLast()) { return Int(number * 1024) }
        if lower.hasSuffix("m"), let number = Int(lower.dropLast()) { return number }
        if lower.hasSuffix("k"), let number = Int(lower.dropLast()) { return number / 1024 }
        return Int(lower)
    }

    /// Classifies an AVD from its system image tags, then its device profile name, then its
    /// hardware (a hinge means foldable; that has to come before the screen-size check, since a
    /// foldable's configured screen is its large unfolded size).
    static func formFactor(config: [String: String], tagIDs: [String]) -> VirtualDevice.FormFactor {
        let tags = tagIDs.map { $0.lowercased() }
        let device = (config["hw.device.name"] ?? "").lowercased()
        func tag(_ matches: (String) -> Bool) -> Bool { tags.contains(where: matches) }

        if tag({ $0 == "android-tv" || $0 == "google-tv" }) || device.hasPrefix("tv_") { return .tv }
        if tag({ $0.contains("wear") }) || device.hasPrefix("wearos_") { return .wear }
        if tag({ $0.contains("automotive") }) || device.hasPrefix("automotive_") { return .automotive }
        if tag({ $0.contains("desktop") }) || device.hasPrefix("desktop_") || device.contains("freeform") { return .desktop }
        if tag({ $0.contains("glasses") }) || device.contains("glasses") { return .glasses }
        if tag({ $0 == "android-xr" || $0.hasSuffix("_xr") }) || device.hasPrefix("xr_") { return .xr }
        // The experimental resizable phone defines hinge postures but Android Studio lists it as a phone.
        if device.contains("resizable") { return .phone }
        if config["hw.sensor.hinge"]?.lowercased() == "yes" || device.contains("fold") { return .foldable }
        if tag({ $0.hasSuffix("_tablet") }) || device.contains("tablet") { return .tablet }
        if let width = config["hw.lcd.width"].flatMap(Double.init),
           let height = config["hw.lcd.height"].flatMap(Double.init),
           let density = config["hw.lcd.density"].flatMap(Double.init), density > 0,
           min(width, height) * 160 / density >= 600 {
            return .tablet
        }
        return .phone
    }
}

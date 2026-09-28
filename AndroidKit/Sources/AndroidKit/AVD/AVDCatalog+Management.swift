import Foundation

extension AVDCatalog {
    /// Moves an AVD's folder and `.ini` to the Trash, so a mistaken delete can be undone.
    public func delete(_ device: VirtualDevice, running: [RunningEmulator] = RunningEmulators.scan()) throws {
        guard RunningEmulators.instance(of: device, in: running) == nil else { throw AVDError.running(device.displayName) }
        try FileManager.default.trashItem(at: URL(fileURLWithPath: device.path), resultingItemURL: nil)
        try FileManager.default.trashItem(at: URL(fileURLWithPath: device.iniPath), resultingItemURL: nil)
    }

    /// Files removed by "Wipe Data" (same set as Android Studio). The emulator recreates them
    /// from the system image on the next boot, which is then a factory-fresh cold boot.
    static let userDataFiles = ["userdata-qemu.img", "userdata-qemu.img.qcow2", "cache.img", "cache.img.qcow2", "snapshots"]

    /// Resets an AVD to factory state: user data, cache and snapshots are deleted.
    public func wipeData(_ device: VirtualDevice, running: [RunningEmulator] = RunningEmulators.scan()) throws {
        guard RunningEmulators.instance(of: device, in: running) == nil else { throw AVDError.running(device.displayName) }
        let folder = URL(fileURLWithPath: device.path, isDirectory: true)
        for name in Self.userDataFiles {
            let url = folder.appending(path: name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Applies an issue's fix: removes a dangling `.ini` (to the Trash), or writes the missing
    /// `.ini` for an unregistered folder so the emulator can see it again.
    public func fix(_ issue: AVDIssue) throws {
        switch issue.kind {
        case .missingFolder:
            guard let iniPath = issue.iniPath else { return }
            try FileManager.default.trashItem(at: URL(fileURLWithPath: iniPath), resultingItemURL: nil)
        case .unregisteredFolder:
            try register(folder: URL(fileURLWithPath: issue.folderPath, isDirectory: true), preferredName: issue.name)
        }
    }

    /// Writes `<name>.ini` pointing at `folder`, picking a free name if `preferredName` is taken.
    @discardableResult
    func register(folder: URL, preferredName: String) throws -> String {
        let config = PropertiesFile.load(folder.appending(path: "config.ini")) ?? [:]
        var name = preferredName
        var counter = 2
        while FileManager.default.fileExists(atPath: directory.appending(path: "\(name).ini").path) {
            name = "\(preferredName)_\(counter)"
            counter += 1
        }

        var lines = [
            "avd.ini.encoding=UTF-8",
            "path=\(folder.path)",
            "path.rel=\(directory.lastPathComponent)/\(folder.lastPathComponent)",
        ]
        if let target = config["target"] { lines.append("target=\(target)") }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: directory.appending(path: "\(name).ini"), atomically: true, encoding: .utf8)
        return name
    }
}

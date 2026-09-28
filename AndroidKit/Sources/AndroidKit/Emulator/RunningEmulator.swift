import Foundation

/// A running emulator instance, read from the discovery file the emulator writes at
/// `~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini`.
public struct RunningEmulator: Sendable, Equatable, Codable, Identifiable {
    public var pid: Int32
    /// The AVD name (`avd.id`), as used with `emulator -avd`.
    public var avdName: String
    public var avdPath: String?
    /// Console port; the adb serial is `emulator-<port>`.
    public var consolePort: Int
    public var emulatorVersion: String?
    public var headless: Bool

    public var id: Int32 { pid }
    public var serial: String { "emulator-\(consolePort)" }
}

public enum RunningEmulators {
    /// Where the emulator publishes running instances on macOS.
    public static var discoveryDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/TemporaryItems/avd/running", directoryHint: .isDirectory)
    }

    /// Running emulators, skipping stale files left behind by crashed instances.
    public static func scan(directory: URL = discoveryDirectory) -> [RunningEmulator] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return entries.compactMap { entry -> RunningEmulator? in
            guard entry.hasPrefix("pid_"), entry.hasSuffix(".ini"),
                  let pid = Int32(entry.dropFirst(4).dropLast(4)),
                  DetachedProcess.isRunning(pid),
                  let info = PropertiesFile.load(directory.appending(path: entry))
            else { return nil }
            return parse(info, pid: pid)
        }
        .sorted { $0.consolePort < $1.consolePort }
    }

    /// Whether an emulator that's no longer running left its discovery file behind, which
    /// means it crashed or was killed: a normal exit (closing its window) removes the file.
    public static func exitedUncleanly(_ emulator: RunningEmulator, directory: URL = discoveryDirectory) -> Bool {
        !DetachedProcess.isRunning(emulator.pid)
            && FileManager.default.fileExists(atPath: directory.appending(path: "pid_\(emulator.pid).ini").path)
    }

    static func parse(_ info: [String: String], pid: Int32) -> RunningEmulator? {
        guard let avdName = info["avd.id"], let port = info["port.serial"].flatMap(Int.init) else { return nil }
        let commandLine = info["cmdline"] ?? ""
        return RunningEmulator(
            pid: pid,
            avdName: avdName,
            avdPath: info["avd.dir"],
            consolePort: port,
            emulatorVersion: info["emulator.version"],
            headless: commandLine.contains("-no-window") || commandLine.contains("-headless")
        )
    }

    /// The running instance of an AVD, matched by name or folder.
    public static func instance(of device: VirtualDevice, in running: [RunningEmulator]) -> RunningEmulator? {
        running.first { emulator in
            emulator.avdName == device.name
                || emulator.avdPath.map { SDKLocator.Candidate.samePath($0, device.path) } == true
        }
    }
}

import Foundation

public enum EmulatorActionError: Error, Sendable, Equatable, LocalizedError {
    case adbMissing
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .adbMissing: "adb isn't installed (it comes with the Platform Tools package)."
        case let .failed(message): message
        }
    }
}

/// Quick actions on a running emulator, mostly for React Native development.
public struct EmulatorActions: Sendable {
    public let adb: ADB
    public let serial: String

    public init(sdkRoot: URL, serial: String) {
        adb = ADB(sdkRoot: sdkRoot)
        self.serial = serial
    }

    /// `adb reverse tcp:<port> tcp:<port>`: the device reaches the Mac's port as its own
    /// localhost (Metro on 8081 by default).
    public func reverse(port: Int = 8081) async throws {
        try await run(["reverse", "tcp:\(port)", "tcp:\(port)"], failure: "Couldn't forward port \(port)")
    }

    /// Opens React Native's developer menu (the menu key).
    public func openDevMenu() async throws {
        try await run(["shell", "input", "keyevent", "82"], failure: "Couldn't open the developer menu")
    }

    /// Reloads the React Native app in front (pressing R twice, as in the emulator window).
    public func reloadApp() async throws {
        try await run(["shell", "input", "keyevent", "46", "46"], failure: "Couldn't reload the app")
    }

    /// Saves a PNG screenshot to `destination`.
    public func screenshot(to destination: URL) async throws {
        try check()
        let result = try await adb.run(["-s", serial, "exec-out", "screencap", "-p"], timeout: .seconds(30))
        // PNG files start with 0x89 'P' 'N' 'G'.
        guard result.succeeded, result.stdout.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            throw EmulatorActionError.failed("Couldn't take a screenshot: \(Self.message(result))")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try result.stdout.write(to: destination)
    }

    /// Installs (or updates) an APK, allowing test builds and downgrades of debug builds.
    public func install(apk: URL) async throws {
        try check()
        let result = try await adb.run(["-s", serial, "install", "-r", "-t", "-d", apk.path], timeout: .seconds(300))
        let output = result.stdoutString + result.stderrString
        guard result.succeeded, output.contains("Success") else {
            let reason = output.split(whereSeparator: \.isNewline)
                .first { $0.contains("Failure") || $0.contains("failed") || $0.contains("error") }
                .map(String.init) ?? Self.message(result)
            throw EmulatorActionError.failed("Couldn't install \(apk.lastPathComponent): \(reason)")
        }
    }

    /// Where screenshots go by default: the folder macOS screenshots use (usually the Desktop).
    public static func defaultScreenshotURL(deviceName: String, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let folder = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
            .map { URL(fileURLWithPath: ShellEnvironment.expandTilde($0), isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop", directoryHint: .isDirectory)
        return folder.appending(path: "\(deviceName) \(formatter.string(from: date)).png")
    }

    private func check() throws {
        guard adb.isInstalled else { throw EmulatorActionError.adbMissing }
    }

    private func run(_ arguments: [String], failure: String) async throws {
        try check()
        let result = try await adb.run(["-s", serial] + arguments)
        guard result.succeeded else { throw EmulatorActionError.failed("\(failure): \(Self.message(result))") }
    }

    private static func message(_ result: ProcessResult) -> String {
        let text = (result.stderrString + result.stdoutString).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "adb exited with code \(result.exitCode)" : text
    }
}

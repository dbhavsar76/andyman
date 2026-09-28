import Foundation

/// Minimal `adb` wrapper for the few calls we need.
public struct ADB: Sendable {
    public let executable: URL
    private let runner: ProcessRunner

    public init(sdkRoot: URL, runner: ProcessRunner = ProcessRunner()) {
        executable = sdkRoot.appending(path: "platform-tools/adb")
        self.runner = runner
    }

    public var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }

    @discardableResult
    public func run(_ arguments: [String], timeout: Duration = .seconds(15)) async throws -> ProcessResult {
        try await runner.run(executable, arguments: arguments, timeout: timeout)
    }

    /// Runs a shell command on a device and returns trimmed stdout, or nil if it failed.
    public func shell(_ serial: String, _ command: String, timeout: Duration = .seconds(10)) async -> String? {
        guard let result = try? await run(["-s", serial, "shell", command], timeout: timeout), result.succeeded else { return nil }
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether Android has finished booting (`sys.boot_completed` is 1).
    public func isBootCompleted(_ serial: String) async -> Bool {
        await shell(serial, "getprop sys.boot_completed", timeout: .seconds(5)) == "1"
    }

    /// Sends a command to the emulator console, e.g. `kill`.
    public func emulatorConsole(_ serial: String, _ command: [String]) async throws -> ProcessResult {
        try await run(["-s", serial, "emu"] + command)
    }
}

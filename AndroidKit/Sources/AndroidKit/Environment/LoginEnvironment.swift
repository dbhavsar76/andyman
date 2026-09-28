import Foundation

/// Fills in toolchain variables from the user's login shell when a process doesn't have them.
///
/// Coding agents and IDEs often run commands in shells that don't load `~/.zshrc`, so
/// `ANDROID_HOME` and `JAVA_HOME` are missing there even though the user's terminal has them.
/// Judging that bare environment gives wrong answers ("no ANDROID_HOME", the wrong JDK), so the
/// CLI overlays what the login shell would set, and says which values came from the profile.
public enum LoginEnvironment {
    /// Variables worth taking from the profile.
    static let keys = ["ANDROID_HOME", "ANDROID_SDK_ROOT", "JAVA_HOME", "FLUTTER_ROOT", "GRADLE_USER_HOME", "ANDROID_USER_HOME"]
    /// Profile files whose changes invalidate the cache.
    static let profileFiles = [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".bash_profile", ".bashrc", ".profile", ".config/fish/config.fish"]

    public struct Overlay: Sendable, Equatable {
        public var environment: [String: String]
        /// Variables that came from the login shell, not the process.
        public var fromProfile: Set<String>
    }

    /// `environment` plus any missing toolchain variables (and PATH entries) from the login
    /// shell. Skipped when nothing's missing, on CI, or with `ANDYMAN_NO_SHELL_ENV=1`.
    public static func overlay(_ environment: [String: String], login: () -> [String: String]? = { cachedOrCaptured() }) -> Overlay {
        let hasSDK = environment["ANDROID_HOME"] != nil || environment["ANDROID_SDK_ROOT"] != nil
        let skip = environment["ANDYMAN_NO_SHELL_ENV"] == "1" || environment["CI"] != nil
        guard !skip, !hasSDK || environment["JAVA_HOME"] == nil, let login = login() else {
            return Overlay(environment: environment, fromProfile: [])
        }
        var merged = environment
        var fromProfile: Set<String> = []
        for key in keys where environment[key] == nil {
            if let value = login[key], !value.isEmpty {
                merged[key] = value
                fromProfile.insert(key)
            }
        }
        // Append PATH entries the profile adds (adb, emulator, andyman), keeping the process's order.
        let current = ShellEnvironment.pathEntries(environment)
        let missing = ShellEnvironment.pathEntries(login).filter { !current.contains($0) }
        if !missing.isEmpty {
            merged["PATH"] = (current + missing).joined(separator: ":")
            fromProfile.insert("PATH")
        }
        return Overlay(environment: merged, fromProfile: fromProfile)
    }

    private struct Cache: Codable {
        var capturedAt: Date
        var profileDates: [String: Date]
        var environment: [String: String]
    }

    static var cacheFile: URL {
        RepositoryClient.defaultCacheDirectory.deletingLastPathComponent().appending(path: "login-environment.json")
    }

    /// The login shell's toolchain variables, from a cache that's reused until a profile file
    /// changes (or a day passes), else captured by running the login shell (a second or so).
    public static func cachedOrCaptured(shell: String? = nil) -> [String: String]? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dates: [String: Date] = [:]
        for file in profileFiles {
            let url = home.appending(path: file)
            if let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
                dates[file] = date
            }
        }
        if let data = try? Data(contentsOf: cacheFile),
           let cache = try? JSONDecoder().decode(Cache.self, from: data),
           cache.profileDates == dates,
           Date().timeIntervalSince(cache.capturedAt) < 24 * 60 * 60 {
            return cache.environment
        }
        guard let captured = captureSynchronously(shell: shell) else { return nil }
        let relevant = captured.filter { keys.contains($0.key) || $0.key == "PATH" }
        let cache = Cache(capturedAt: Date(), profileDates: dates, environment: relevant)
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheFile, options: .atomic) }
        return relevant
    }

    /// Runs the login shell and reads its environment, giving up after `timeout`.
    static func captureSynchronously(shell: String?, timeout: TimeInterval = 5) -> [String: String]? {
        let shellPath = shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-l", "-i", "-c", "printf '\(ShellEnvironment.startMarker)'; /usr/bin/env -0; printf '\(ShellEnvironment.endMarker)'"]
        var environment = ProcessInfo.processInfo.environment
        environment["ANDYMAN_NO_SHELL_ENV"] = "1" // in case the profile runs andyman
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        // Read while it runs so a chatty profile can't fill the pipe and stall.
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.data = output.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        _ = readDone.wait(timeout: .now() + 1)
        return ShellEnvironment.parse(box.data)
    }
}

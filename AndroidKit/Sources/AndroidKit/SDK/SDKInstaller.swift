import Darwin
import Foundation

public enum InstallEvent: Sendable, Equatable {
    /// Work on a package began (dependencies come first).
    case started(String)
    /// Bytes downloaded so far for a package.
    case downloading(String, received: Int64, total: Int64)
    /// Download finished; unpacking into the SDK.
    case unpacking(String)
    case finished(String)
    /// A line of tool output, for logs.
    case output(String)
}

public enum SDKInstallError: Error, Sendable, Equatable, LocalizedError {
    case toolsMissing
    case javaMissing
    case locked
    case failed(String, output: String)

    public var errorDescription: String? {
        switch self {
        case .toolsMissing: "Installing packages needs the Android SDK Command-line Tools."
        case .javaMissing: "The installed Command-line Tools need a JDK \(JavaLocator.minimumMajorVersion) or newer."
        case .locked: "Another install is already running for this SDK."
        case let .failed(id, output): "Couldn't install \(id)." + (output.isEmpty ? "" : " \(output)")
        }
    }
}

/// Installs and removes SDK packages.
///
/// Uses the Android CLI (`cmdline-tools/…/bin/android`, the successor to `sdkmanager`) when
/// present: it's a native binary, needs no JDK and handles dependencies itself. Older
/// command-line tools fall back to the Java `sdkmanager`.
public struct SDKInstaller: Sendable {
    enum Backend: Equatable {
        case androidCLI(URL)
        case sdkmanager(URL)
    }

    public let sdkRoot: URL
    public let java: JavaInstallation?
    public let environment: [String: String]
    private let runner = ProcessRunner()

    public init(sdkRoot: URL, java: JavaInstallation?, environment: [String: String]) {
        self.sdkRoot = sdkRoot
        self.java = java
        self.environment = environment
    }

    /// Whether the SDK has command-line tools that can install packages.
    public var isAvailable: Bool { (try? backend()) != nil }

    /// Which tool to drive: the newest command-line tools with the Android CLI, otherwise any
    /// real (non-wrapper) `sdkmanager`.
    func backend() throws -> Backend {
        let tools = SDKInspector.subpackages(of: sdkRoot, folder: "cmdline-tools")
            .sorted { $0.id == "cmdline-tools;latest" || ($1.id != "cmdline-tools;latest" && VersionComparator.isLess($1.version ?? "", $0.version ?? "")) }
        for package in tools {
            let cli = URL(fileURLWithPath: package.path).appending(path: "bin/android")
            if FileManager.default.isExecutableFile(atPath: cli.path) { return .androidCLI(cli) }
        }
        for package in tools {
            let sdkmanager = URL(fileURLWithPath: package.path).appending(path: "bin/sdkmanager")
            guard FileManager.default.isExecutableFile(atPath: sdkmanager.path) else { continue }
            let script = (try? String(contentsOf: sdkmanager, encoding: .utf8)) ?? ""
            if !script.contains("run_android_cli") { return .sdkmanager(sdkmanager) }
        }
        throw SDKInstallError.toolsMissing
    }

    // MARK: - Install

    /// Installs a plan's packages one at a time (dependencies first), streaming progress.
    /// Licenses must already have been accepted by the user. Cancelling stops the current
    /// download; already-installed packages stay installed.
    public func install(_ plan: InstallPlan) -> AsyncThrowingStream<InstallEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let lock = try SDKLock.acquire(sdkRoot: sdkRoot)
                    defer { lock.release() }
                    let backend = try backend()
                    for package in plan.packages {
                        try Task.checkCancellation()
                        if isInstalled(package) {
                            continuation.yield(.finished(package.id))
                            continue
                        }
                        continuation.yield(.started(package.id))
                        try await install(package, backend: backend) { continuation.yield($0) }
                        continuation.yield(.finished(package.id))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func install(_ package: RemotePackage, backend: Backend, emit: @escaping @Sendable (InstallEvent) -> Void) async throws {
        var output: [String] = []
        let events: AsyncThrowingStream<ProcessEvent, any Error>
        var progress: Task<Void, Never>?

        switch backend {
        case let .androidCLI(cli):
            var arguments = ["--no-metrics", "--sdk=\(sdkRoot.path)", "sdk", "install"]
            switch package.channel {
            case .stable: break
            case .beta: arguments.append("--beta")
            case .dev, .canary: arguments.append("--canary")
            }
            arguments.append("\(package.id.replacingOccurrences(of: ";", with: "/"))@\(Self.versionString(package.revision))")
            events = runner.lines(cli, arguments: arguments, environment: environment)
            // The Android CLI prints no progress, but downloads to `.sdk/arch/<sha1>.part`.
            if let archive = package.archive {
                progress = Task { await watchDownload(of: package.id, archive: archive, emit: emit) }
            }
        case let .sdkmanager(sdkmanager):
            guard let java else { throw SDKInstallError.javaMissing }
            var environment = environment
            environment["JAVA_HOME"] = java.home
            events = runner.lines(
                sdkmanager,
                arguments: ["--sdk_root=\(sdkRoot.path)", "--channel=\(package.channel.rawValue)", package.id],
                environment: environment,
                // Licenses were accepted in our UI; answer sdkmanager's prompts.
                standardInput: Data(String(repeating: "y\n", count: 20).utf8)
            )
        }
        defer { progress?.cancel() }

        for try await event in events {
            switch event {
            case let .stdout(line), let .stderr(line):
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                emit(.output(trimmed))
                output.append(trimmed)
                if case .sdkmanager = backend { parseSDKManagerProgress(trimmed, package: package, emit: emit) }
            case .exited:
                break
            }
        }
        progress?.cancel()

        // The Android CLI exits 0 even when a package can't be found, so check the result on disk.
        guard isInstalled(package) else {
            let reason = output.last { !$0.hasPrefix("http") && !$0.hasPrefix("[") } ?? ""
            throw SDKInstallError.failed(package.id, output: reason)
        }
    }

    /// `36.1.0` → `36.1.0`; the Android CLI accepts `pkg@version`.
    static func versionString(_ revision: PackageRevision) -> String {
        var text = "\(revision.major).\(revision.minor).\(revision.micro)"
        if let preview = revision.preview { text += "-rc\(preview)" }
        return text
    }

    func isInstalled(_ package: RemotePackage) -> Bool {
        guard let directory = Self.directory(for: package.id, in: sdkRoot),
              let local = LocalPackages.package(at: directory)
        else { return false }
        return local.revision >= package.revision
    }

    /// `ndk;27.1.12297006` → `<sdk>/ndk/27.1.12297006`.
    static func directory(for id: String, in sdkRoot: URL) -> URL? {
        let components = id.split(separator: ";").map(String.init)
        guard !components.isEmpty else { return nil }
        return components.reduce(sdkRoot) { $0.appending(path: $1, directoryHint: .isDirectory) }
    }

    private func watchDownload(of id: String, archive: RemotePackage.Archive, emit: @Sendable (InstallEvent) -> Void) async {
        let part = sdkRoot.appending(path: ".sdk/arch/\(archive.sha1).part")
        var sawDownload = false
        var lastReported: Int64 = -1
        while !Task.isCancelled {
            let size = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? nil
            if let size {
                sawDownload = true
                if size != lastReported {
                    emit(.downloading(id, received: min(size, archive.size), total: archive.size))
                    lastReported = size
                }
            } else if sawDownload {
                // The .part file is gone: downloaded and now unpacking.
                emit(.downloading(id, received: archive.size, total: archive.size))
                emit(.unpacking(id))
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func parseSDKManagerProgress(_ line: String, package: RemotePackage, emit: (InstallEvent) -> Void) {
        let total = package.archive?.size ?? 0
        if line.localizedCaseInsensitiveContains("unzipping") || line.localizedCaseInsensitiveContains("installing") {
            emit(.unpacking(package.id))
        } else if let match = line.firstMatch(of: /(\d{1,3})%/), let percent = Int64(match.1), total > 0 {
            emit(.downloading(package.id, received: total * percent / 100, total: total))
        }
    }

    // MARK: - Remove

    /// Removes packages (e.g. an NDK version you no longer need).
    public func uninstall(_ ids: [String]) async throws {
        let lock = try SDKLock.acquire(sdkRoot: sdkRoot)
        defer { lock.release() }
        let backend = try backend()
        for id in ids.map(SDKPackageID.normalize) {
            let result: ProcessResult
            switch backend {
            case let .androidCLI(cli):
                result = try await runner.run(cli, arguments: ["--no-metrics", "--sdk=\(sdkRoot.path)", "sdk", "remove", id.replacingOccurrences(of: ";", with: "/")], environment: environment, timeout: .seconds(600))
            case let .sdkmanager(sdkmanager):
                guard let java else { throw SDKInstallError.javaMissing }
                var environment = environment
                environment["JAVA_HOME"] = java.home
                result = try await runner.run(sdkmanager, arguments: ["--sdk_root=\(sdkRoot.path)", "--uninstall", id], environment: environment, timeout: .seconds(600))
            }
            if let directory = Self.directory(for: id, in: sdkRoot), FileManager.default.fileExists(atPath: directory.appending(path: "package.xml").path) {
                throw SDKInstallError.failed(id, output: result.stderrString.isEmpty ? result.stdoutString : result.stderrString)
            }
        }
    }
}

/// An advisory lock so the app and the CLI never run installs into the same SDK at once.
public final class SDKLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    public static func lockFile(sdkRoot: URL) -> URL {
        sdkRoot.appending(path: ".andyman.lock")
    }

    /// Fails immediately with `.locked` if another process holds the lock.
    public static func acquire(sdkRoot: URL) throws -> SDKLock {
        let path = lockFile(sdkRoot: sdkRoot).path
        let descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { throw SDKInstallError.failed("lock", output: String(cString: strerror(errno))) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw SDKInstallError.locked
        }
        return SDKLock(descriptor: descriptor)
    }

    public func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

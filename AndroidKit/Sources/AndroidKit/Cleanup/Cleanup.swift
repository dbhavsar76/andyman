import Foundation

/// Something that takes disk space and can be safely deleted (it's re-created when needed).
public struct CleanupTarget: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case gradleCaches = "gradle-caches"
        case gradleDistribution = "gradle-distribution"
        case gradleDaemonLogs = "gradle-daemon-logs"
        case androidCache = "android-cache"
        case emulatorSnapshots = "emulator-snapshots"
        case metroCache = "metro-cache"
        case sdkLeftovers = "sdk-leftovers"
        case projectBuild = "project-build"
        case projectLibraries = "project-libraries"
    }

    /// Stable identifier for the CLI, e.g. `gradle-caches` or `gradle-distribution:gradle-8.14.3-bin`.
    public var id: String
    public var kind: Kind
    public var title: String
    public var detail: String
    public var paths: [String]
    /// Gradle must not be running while these are deleted.
    public var needsGradleStopped: Bool
    /// Safe to pick without thinking (nothing slow to get back).
    public var recommended: Bool

    public init(id: String, kind: Kind, title: String, detail: String, paths: [String], needsGradleStopped: Bool = false, recommended: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.paths = paths
        self.needsGradleStopped = needsGradleStopped
        self.recommended = recommended
    }
}

/// Finds and deletes caches the Android toolchain leaves behind.
public struct Cleanup: Sendable {
    public var home: URL
    public var gradleUserHome: URL
    public var temporaryDirectory: URL
    public var sdkRoot: URL?
    public var androidUserHome: URL

    public init(
        sdkRoot: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.home = home
        self.sdkRoot = sdkRoot
        self.temporaryDirectory = temporaryDirectory
        if let gradle = environment["GRADLE_USER_HOME"], !gradle.isEmpty {
            gradleUserHome = URL(fileURLWithPath: gradle, isDirectory: true)
        } else {
            gradleUserHome = home.appending(path: ".gradle", directoryHint: .isDirectory)
        }
        if let android = environment["ANDROID_USER_HOME"], !android.isEmpty {
            androidUserHome = URL(fileURLWithPath: android, isDirectory: true)
        } else {
            androidUserHome = home.appending(path: ".android", directoryHint: .isDirectory)
        }
    }

    /// Everything we can clean, without sizes (see `size(of:)`). Emulators in `running`
    /// keep their snapshots: the emulator has them open.
    public func targets(devices: [VirtualDevice] = [], running: Set<String> = []) -> [CleanupTarget] {
        let fileManager = FileManager.default
        func exists(_ url: URL) -> Bool { fileManager.fileExists(atPath: url.path) }
        var targets: [CleanupTarget] = []

        let caches = gradleUserHome.appending(path: "caches")
        if exists(caches) {
            targets.append(CleanupTarget(
                id: Kind.gradleCaches.rawValue, kind: .gradleCaches,
                title: "Gradle Caches",
                detail: "Downloaded libraries and build outputs. The next build downloads and rebuilds them, so it's slower.",
                paths: [caches.path], needsGradleStopped: true
            ))
        }

        let dists = gradleUserHome.appending(path: "wrapper/dists")
        let distributions = SDKInspector.childDirectories(of: dists)
            .sorted { VersionComparator.isLess($1.lastPathComponent, $0.lastPathComponent) }
        for distribution in distributions {
            let name = distribution.lastPathComponent
            let version = name.replacingOccurrences(of: "gradle-", with: "")
                .replacingOccurrences(of: "-bin", with: "")
                .replacingOccurrences(of: "-all", with: " (with sources)")
            targets.append(CleanupTarget(
                id: "\(Kind.gradleDistribution.rawValue):\(name)", kind: .gradleDistribution,
                title: "Gradle \(version)",
                detail: "Downloaded by the Gradle wrapper, and again by any project that uses it.",
                paths: [distribution.path], needsGradleStopped: true
            ))
        }

        let daemonLogs = SDKInspector.childDirectories(of: gradleUserHome.appending(path: "daemon")).flatMap { folder in
            ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasSuffix(".log") }
                .map { folder.appending(path: $0).path }
        }
        if !daemonLogs.isEmpty {
            targets.append(CleanupTarget(
                id: Kind.gradleDaemonLogs.rawValue, kind: .gradleDaemonLogs,
                title: "Gradle Daemon Logs",
                detail: "Logs from past Gradle daemons.",
                paths: daemonLogs, recommended: true
            ))
        }

        let androidCache = androidUserHome.appending(path: "cache")
        if exists(androidCache) {
            targets.append(CleanupTarget(
                id: Kind.androidCache.rawValue, kind: .androidCache,
                title: "Android Tools Cache",
                detail: "Temporary files from the SDK tools in ~/.android/cache.",
                paths: [androidCache.path], recommended: true
            ))
        }

        let metro = ((try? fileManager.contentsOfDirectory(atPath: temporaryDirectory.path)) ?? [])
            .filter { $0.hasPrefix("metro-") || $0.hasPrefix("haste-map-") || $0.hasPrefix("react-native-packager-cache-") }
            .map { temporaryDirectory.appending(path: $0).path }
        if !metro.isEmpty {
            targets.append(CleanupTarget(
                id: Kind.metroCache.rawValue, kind: .metroCache,
                title: "Metro Cache",
                detail: "React Native's bundler cache (like starting Metro with --reset-cache). Stop Metro first.",
                paths: metro, recommended: true
            ))
        }

        if let sdkRoot {
            var leftovers = [".temp", "temp", ".downloadIntermediates"]
                .map { sdkRoot.appending(path: $0) }
                .filter(exists)
            // Left aside when broken command-line tools were replaced during setup.
            leftovers += SDKInspector.childDirectories(of: sdkRoot.appending(path: "cmdline-tools"))
                .filter { $0.lastPathComponent.hasPrefix("latest-old-") }
            if !leftovers.isEmpty {
                targets.append(CleanupTarget(
                    id: Kind.sdkLeftovers.rawValue, kind: .sdkLeftovers,
                    title: "SDK Download Leftovers",
                    detail: "Unfinished downloads and temporary folders in the SDK.",
                    paths: leftovers.map(\.path), recommended: true
                ))
            }
        }

        for device in devices where !running.contains(device.name) {
            let snapshots = URL(fileURLWithPath: device.path).appending(path: "snapshots")
            guard !SDKInspector.childDirectories(of: snapshots).isEmpty else { continue }
            targets.append(CleanupTarget(
                id: "\(Kind.emulatorSnapshots.rawValue):\(device.name)", kind: .emulatorSnapshots,
                title: "\(device.displayName) Snapshots",
                detail: "Saved emulator states, including Quick Boot. The next start is a cold boot.",
                paths: [snapshots.path]
            ))
        }
        return targets
    }

    /// Build outputs of a project: what `./gradlew clean` removes plus native (`.cxx`) and
    /// Gradle project caches, then the same for React Native libraries in `node_modules`.
    public static func projectTargets(_ project: AndroidProject) -> [CleanupTarget] {
        let fileManager = FileManager.default
        let android = project.androidRootURL
        var own = [android.appending(path: "build"), android.appending(path: ".gradle"), android.appending(path: ".kotlin")]
        for module in SDKInspector.childDirectories(of: android) where AndroidProject.hasBuildFile(module) {
            own += [module.appending(path: "build"), module.appending(path: ".cxx")]
        }
        // Flutter sends Gradle's output to the project's own build/ folder (what `flutter clean` deletes).
        if project.framework == .flutter { own.append(URL(fileURLWithPath: project.root).appending(path: "build")) }
        own = own.filter { fileManager.fileExists(atPath: $0.path) }

        var libraries: [URL] = []
        let nodeModules = URL(fileURLWithPath: project.root).appending(path: "node_modules")
        var packages = SDKInspector.childDirectories(of: nodeModules).filter { !$0.lastPathComponent.hasPrefix(".") }
        packages = packages.flatMap { package in
            package.lastPathComponent.hasPrefix("@") ? SDKInspector.childDirectories(of: package) : [package]
        }
        for package in packages {
            let androidFolder = package.appending(path: "android")
            libraries += [androidFolder.appending(path: "build"), androidFolder.appending(path: ".cxx")]
                .filter { fileManager.fileExists(atPath: $0.path) }
        }

        var targets: [CleanupTarget] = []
        if !own.isEmpty {
            targets.append(CleanupTarget(
                id: Kind.projectBuild.rawValue, kind: .projectBuild,
                title: project.framework == .flutter ? "Build Folders" : "Android Build Folders",
                detail: project.framework == .flutter
                    ? "build/, native .cxx and android/.gradle folders, like flutter clean for Android. Fixes most stale build errors."
                    : "android/build, app/build, native .cxx and .gradle folders. Fixes most stale native build errors.",
                paths: own.map(\.path), needsGradleStopped: true, recommended: true
            ))
        }
        if !libraries.isEmpty {
            targets.append(CleanupTarget(
                id: Kind.projectLibraries.rawValue, kind: .projectLibraries,
                title: "Library Build Folders",
                detail: "Build outputs of native modules in node_modules (\(libraries.count) \(libraries.count == 1 ? "folder" : "folders")).",
                paths: libraries.map(\.path), needsGradleStopped: true, recommended: true
            ))
        }
        return targets
    }

    /// Disk space a target uses, in bytes. Can take a while for large caches.
    public static func size(of target: CleanupTarget) -> Int64 {
        target.paths.reduce(0) { $0 + diskSize(URL(fileURLWithPath: $1)) }
    }

    /// Deletes a target's files for good (these are caches, so they aren't moved to the Trash).
    /// Returns the bytes freed. Paths that are already gone are skipped.
    @discardableResult
    public static func clean(_ target: CleanupTarget) throws -> Int64 {
        var freed: Int64 = 0
        for path in target.paths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let size = diskSize(url)
            try FileManager.default.removeItem(at: url)
            freed += size
        }
        return freed
    }

    static func diskSize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isDirectory == true { return AVDCatalog.folderSize(url) }
        return Int64(values.totalFileAllocatedSize ?? 0)
    }

    private typealias Kind = CleanupTarget.Kind
}

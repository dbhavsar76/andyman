import Foundation

public struct JavaInstallation: Sendable, Equatable, Codable, Identifiable {
    public var home: String
    public var version: String?
    public var vendor: String?
    public var name: String?
    public var source: LocationSource

    public var id: String { home }
    public var majorVersion: Int? { version.flatMap(VersionComparator.majorVersion) }
    public var javaExecutable: String { "\(home)/bin/java" }

    /// "JDK 21 · Amazon Corretto 21" style label for UI.
    public var displayName: String {
        let major = majorVersion.map { "JDK \($0)" } ?? "JDK"
        guard let name else { return major }
        return "\(major) · \(name)"
    }

    public init(home: String, version: String?, vendor: String?, name: String?, source: LocationSource) {
        self.home = home
        self.version = version
        self.vendor = vendor
        self.name = name
        self.source = source
    }
}

/// Finds JDKs and picks the one used to run the SDK's Java tools.
public struct JavaLocator: Sendable {
    /// `sdkmanager`/`avdmanager` and current Android Gradle Plugin versions need Java 17+.
    public static let minimumMajorVersion = 17

    public struct Resolution: Sendable, Equatable {
        public var selected: JavaInstallation?
        /// Set when an explicit choice (flag, settings, `JAVA_HOME`) couldn't be used.
        public var rejected: [Rejection]
        public var installations: [JavaInstallation]
    }

    public struct Rejection: Sendable, Equatable, Codable {
        public var path: String
        public var source: LocationSource
        public var reason: Reason

        public enum Reason: String, Sendable, Codable {
            case missing
            case tooOld = "too_old"
        }
    }

    private let runner: ProcessRunner

    public init(runner: ProcessRunner = ProcessRunner()) {
        self.runner = runner
    }

    /// All JDKs we can find: `/usr/libexec/java_home -X`, plus common locations it doesn't
    /// know about (Android Studio's bundled JBR, Homebrew). Newest first.
    public func installations() async -> [JavaInstallation] {
        var found: [JavaInstallation] = []
        if let result = try? await runner.run(
            URL(fileURLWithPath: "/usr/libexec/java_home"),
            arguments: ["-X"],
            timeout: .seconds(5)
        ), result.succeeded {
            found += Self.parseJavaHomeList(result.stdout)
        }
        for home in Self.knownHomes() {
            if let installation = Self.installation(at: home, source: .knownLocation) {
                found.append(installation)
            }
        }
        return Self.deduplicated(found)
            .sorted { VersionComparator.isLess($1.version ?? "", $0.version ?? "") }
    }

    /// The JDK `/usr/bin/java` runs when `JAVA_HOME` isn't set (`java_home`'s default).
    public func systemDefault() async -> JavaInstallation? {
        guard let result = try? await runner.run(URL(fileURLWithPath: "/usr/libexec/java_home"), timeout: .seconds(5)),
              result.succeeded
        else { return nil }
        let home = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.installation(at: home, source: .javaHomeTool)
    }

    /// Order: flag → settings → `JAVA_HOME` → best installed (highest LTS ≥ 17, else highest ≥ 17).
    public func resolve(
        flag: String? = nil,
        settings: String? = nil,
        environment: [String: String],
        installations: [JavaInstallation]
    ) -> Resolution {
        var rejected: [Rejection] = []
        let explicit: [(String?, LocationSource)] = [
            (flag, .flag),
            (settings, .settings),
            (environment["JAVA_HOME"], .environment("JAVA_HOME")),
        ]
        for case let (path?, source) in explicit where !path.isEmpty {
            let home = Self.normalize(path)
            guard let installation = Self.installation(at: home, source: source) else {
                rejected.append(Rejection(path: home, source: source, reason: .missing))
                continue
            }
            guard let major = installation.majorVersion, major >= Self.minimumMajorVersion else {
                rejected.append(Rejection(path: home, source: source, reason: .tooOld))
                continue
            }
            return Resolution(selected: installation, rejected: rejected, installations: installations)
        }
        return Resolution(selected: Self.best(of: installations), rejected: rejected, installations: installations)
    }

    static func best(of installations: [JavaInstallation]) -> JavaInstallation? {
        let usable = installations.filter { ($0.majorVersion ?? 0) >= minimumMajorVersion }
        func isLTS(_ java: JavaInstallation) -> Bool {
            guard let major = java.majorVersion else { return false }
            return (major - 17) % 4 == 0
        }
        let byVersion: (JavaInstallation, JavaInstallation) -> Bool = {
            VersionComparator.isLess($0.version ?? "", $1.version ?? "")
        }
        return usable.filter(isLTS).max(by: byVersion) ?? usable.max(by: byVersion)
    }

    /// Reads a JDK home's `release` file. Returns `nil` if there's no `bin/java`.
    public static func installation(at home: String, source: LocationSource) -> JavaInstallation? {
        guard FileManager.default.isExecutableFile(atPath: "\(home)/bin/java") else { return nil }
        let release = PropertiesFile.load(URL(fileURLWithPath: home).appending(path: "release")) ?? [:]
        func value(_ key: String) -> String? {
            release[key].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return JavaInstallation(
            home: home,
            version: value("JAVA_VERSION"),
            vendor: value("IMPLEMENTOR"),
            name: nil,
            source: source
        )
    }

    /// Parses the plist printed by `java_home -X`.
    static func parseJavaHomeList(_ data: Data) -> [JavaInstallation] {
        guard let entries = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { entry in
            guard let home = entry["JVMHomePath"] as? String else { return nil }
            if let enabled = entry["JVMEnabled"] as? Bool, !enabled { return nil }
            return JavaInstallation(
                home: home,
                version: entry["JVMVersion"] as? String,
                vendor: entry["JVMVendor"] as? String,
                name: entry["JVMName"] as? String,
                source: .javaHomeTool
            )
        }
    }

    static func knownHomes() -> [String] {
        var homes = [
            "/Applications/Android Studio.app/Contents/jbr/Contents/Home",
            "/Applications/Android Studio Preview.app/Contents/jbr/Contents/Home",
        ]
        for prefix in ["/opt/homebrew/opt", "/usr/local/opt"] {
            let formulae = (try? FileManager.default.contentsOfDirectory(atPath: prefix)) ?? []
            for formula in formulae where formula.hasPrefix("openjdk") {
                homes.append("\(prefix)/\(formula)/libexec/openjdk.jdk/Contents/Home")
            }
        }
        // Version managers and Gradle's auto-provisioned toolchains keep JDKs in their own folders.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for folder in [".sdkman/candidates/java", ".local/share/mise/installs/java", ".asdf/installs/java", ".gradle/jdks", ".jenv/versions"] {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: "\(home)/\(folder)")) ?? []
            for entry in entries where !entry.hasPrefix(".") && entry != "current" && entry != "latest" {
                let base = "\(home)/\(folder)/\(entry)"
                // Some keep the macOS bundle layout, some a plain JDK folder.
                homes.append(FileManager.default.fileExists(atPath: "\(base)/Contents/Home/bin/java") ? "\(base)/Contents/Home" : base)
            }
        }
        return homes
    }

    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: ShellEnvironment.expandTilde(path)).standardizedFileURL.path
    }

    /// Keeps the first entry per real path (`java_home` entries come first and carry names).
    static func deduplicated(_ installations: [JavaInstallation]) -> [JavaInstallation] {
        var seen = Set<String>()
        return installations.filter { installation in
            let resolved = URL(fileURLWithPath: installation.home).resolvingSymlinksInPath().path
            return seen.insert(resolved).inserted
        }
    }
}

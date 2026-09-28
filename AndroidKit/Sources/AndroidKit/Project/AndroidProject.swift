import Foundation

public enum ProjectError: Error, Sendable, Equatable, LocalizedError {
    case notFound(String)
    case noAndroidFolder(String)

    public var errorDescription: String? {
        switch self {
        case let .notFound(path): "\(path) doesn't exist."
        case let .noAndroidFolder(path): "\(path) doesn't have an Android project (no android/ folder or build.gradle)."
        }
    }
}

/// A React Native, Flutter or plain Android project's Android build requirements, read from its files.
public struct AndroidProject: Sendable, Equatable, Codable {
    public enum Framework: String, Sendable, Codable {
        case reactNative = "react-native"
        case flutter
        case android
    }

    /// Where a resolved value came from, so the UI can say "from android/build.gradle".
    public enum Source: String, Sendable, Codable {
        case appBuildFile = "app_build_file"
        case rootBuildFile = "root_build_file"
        case gradleProperties = "gradle_properties"
        case reactNativeCatalog = "react_native_catalog"
        case flutterDefault = "flutter_default"
        /// Not set by the project, so the Android Gradle Plugin's default applies.
        case androidGradlePluginDefault = "agp_default"
    }

    public struct Value: Sendable, Equatable, Codable {
        public var value: String
        public var source: Source
    }

    /// The folder the user picked (the React Native project, or the Android project itself).
    public var root: String
    /// The Gradle project folder (`<root>/android` for React Native).
    public var androidRoot: String
    public var name: String
    public var framework: Framework
    public var reactNativeVersion: String?
    public var flutterVersion: String?
    /// The Flutter SDK the project builds with (`flutter.sdk` in local.properties, else `FLUTTER_ROOT` or `flutter` on PATH).
    public var flutterSDK: String?
    /// Set when local.properties names a Flutter SDK that isn't there.
    public var missingFlutterSDK: String?
    public var isExpo: Bool
    public var gradleVersion: String?
    public var androidGradlePluginVersion: String?
    public var compileSdk: Value?
    public var targetSdk: Value?
    public var minSdk: Value?
    public var buildTools: Value?
    public var ndk: Value?
    public var cmake: Value?
    public var newArchitecture: Bool?
    /// ABIs Gradle builds native code for (`reactNativeArchitectures`).
    public var architectures: [String]?
    /// `sdk.dir` from `local.properties`.
    public var localSDKDir: String?
    /// `org.gradle.java.home`, from the Gradle user home or the project (user home wins).
    public var gradleJavaHome: String?
    /// Java version Gradle 8.8+ provisions for its daemon (`gradle-daemon-jvm.properties`).
    public var daemonToolchainVersion: Int?

    public var androidRootURL: URL { URL(fileURLWithPath: androidRoot, isDirectory: true) }

    /// Reads the project at `path`: a React Native or Flutter project, or its `android/` folder.
    public static func load(
        _ path: String,
        gradleUserHome: URL = AndroidProject.defaultGradleUserHome,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> AndroidProject {
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: ShellEnvironment.expandTilde(path)).standardizedFileURL
        guard fileManager.fileExists(atPath: url.path) else { throw ProjectError.notFound(url.path) }

        let androidRoot: URL
        if hasBuildFile(url.appending(path: "android")) {
            androidRoot = url.appending(path: "android", directoryHint: .isDirectory)
        } else if hasBuildFile(url) || fileManager.fileExists(atPath: url.appending(path: "settings.gradle").path) {
            androidRoot = url
        } else {
            throw ProjectError.noAndroidFolder(url.path)
        }
        let projectRoot = androidRoot.lastPathComponent == "android" ? androidRoot.deletingLastPathComponent() : androidRoot

        func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
        let rootScript = buildFile(in: androidRoot).flatMap(read) ?? ""
        let appScript = buildFile(in: androidRoot.appending(path: "app")).flatMap(read) ?? ""
        let properties = PropertiesFile.load(androidRoot.appending(path: "gradle.properties")) ?? [:]
        let userProperties = PropertiesFile.load(gradleUserHome.appending(path: "gradle.properties")) ?? [:]

        let packageJSON = (try? Data(contentsOf: projectRoot.appending(path: "package.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let dependencies = ((packageJSON?["dependencies"] as? [String: Any]) ?? [:])
            .merging((packageJSON?["devDependencies"] as? [String: Any]) ?? [:]) { first, _ in first }
        let reactNative = findPackage("react-native", from: projectRoot)
        let catalog = reactNative
            .flatMap { read($0.appending(path: "gradle/libs.versions.toml")) }
            .map(GradleScript.catalogVersions) ?? [:]

        let localProperties = PropertiesFile.load(androidRoot.appending(path: "local.properties")) ?? [:]
        let pubspec = read(projectRoot.appending(path: "pubspec.yaml"))
        let isFlutter = pubspec.map { $0.range(of: #"sdk:\s*flutter"#, options: .regularExpression) != nil } ?? false
        var flutterSDK: URL?
        var missingFlutterSDK: String?
        if isFlutter {
            (flutterSDK, missingFlutterSDK) = locateFlutterSDK(localProperties: localProperties, environment: environment)
        }
        let flutterDefaults = flutterSDK.flatMap { FlutterDefaults.load(flutterSDK: $0) }

        // Same precedence Gradle ends up with: a literal in app/build.gradle, then the root
        // project's ext values, then Expo's gradle.properties overrides, then the framework's
        // defaults (React Native's version catalog, or the Flutter SDK's `flutter.*` values).
        let appValues = GradleScript.moduleValues(appScript)
        let extValues = GradleScript.extValues(rootScript)
        func resolve(_ key: GradleScript.Key) -> Value? {
            if let value = appValues[key] { return Value(value: value, source: .appBuildFile) }
            if let value = extValues[key] { return Value(value: value, source: .rootBuildFile) }
            if let name = key.expoPropertyName, let value = properties[name] { return Value(value: value, source: .gradleProperties) }
            if let name = key.catalogName, let value = catalog[name] { return Value(value: value, source: .reactNativeCatalog) }
            if let flutterDefaults, let value = flutterDefaults.value(for: key) { return Value(value: value, source: .flutterDefault) }
            return nil
        }

        let wrapper = PropertiesFile.load(androidRoot.appending(path: "gradle/wrapper/gradle-wrapper.properties")) ?? [:]
        let daemonJVM = PropertiesFile.load(androidRoot.appending(path: "gradle/gradle-daemon-jvm.properties")) ?? [:]
        let reactNativeVersion = reactNative
            .flatMap { try? Data(contentsOf: $0.appending(path: "package.json")) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["version"] as? String
            ?? (dependencies["react-native"] as? String).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "^~>=< ")) }

        return AndroidProject(
            root: projectRoot.path,
            androidRoot: androidRoot.path,
            name: (packageJSON?["name"] as? String) ?? pubspec.flatMap(pubspecName) ?? projectRoot.lastPathComponent,
            framework: isFlutter ? .flutter : (reactNative != nil || dependencies["react-native"] != nil ? .reactNative : .android),
            reactNativeVersion: reactNativeVersion,
            flutterVersion: flutterSDK.flatMap(flutterVersion),
            flutterSDK: flutterSDK?.path,
            missingFlutterSDK: missingFlutterSDK,
            isExpo: dependencies["expo"] != nil,
            gradleVersion: wrapper["distributionUrl"].flatMap(GradleScript.wrapperVersion),
            androidGradlePluginVersion: catalog["agp"] ?? GradleScript.androidGradlePluginVersion(
                settings: settingsFile(in: androidRoot).flatMap(read) ?? "",
                rootBuild: rootScript
            ),
            compileSdk: resolve(.compileSdk),
            targetSdk: resolve(.targetSdk),
            minSdk: resolve(.minSdk),
            buildTools: resolve(.buildTools),
            ndk: resolve(.ndk),
            cmake: resolve(.cmake),
            newArchitecture: properties["newArchEnabled"].map { $0 == "true" },
            architectures: properties["reactNativeArchitectures"].map {
                $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            },
            localSDKDir: localProperties["sdk.dir"],
            gradleJavaHome: userProperties["org.gradle.java.home"] ?? properties["org.gradle.java.home"],
            daemonToolchainVersion: daemonJVM["toolchainVersion"].flatMap { Int($0) }
        )
    }

    public static var defaultGradleUserHome: URL {
        if let home = ProcessInfo.processInfo.environment["GRADLE_USER_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".gradle", directoryHint: .isDirectory)
    }

    static func settingsFile(in directory: URL) -> URL? {
        ["settings.gradle", "settings.gradle.kts"]
            .map { directory.appending(path: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The Flutter SDK: `flutter.sdk` from local.properties (written by the flutter tool), else
    /// `FLUTTER_ROOT`, else the `flutter` command on PATH. Also returns a local.properties path
    /// that doesn't exist, to report.
    static func locateFlutterSDK(localProperties: [String: String], environment: [String: String]) -> (URL?, String?) {
        func isSDK(_ url: URL) -> Bool { FileManager.default.isExecutableFile(atPath: url.appending(path: "bin/flutter").path) }
        var missing: String?
        if let path = localProperties["flutter.sdk"] {
            let url = URL(fileURLWithPath: ShellEnvironment.expandTilde(path), isDirectory: true)
            if isSDK(url) { return (url, nil) }
            missing = path
        }
        if let root = environment["FLUTTER_ROOT"], isSDK(URL(fileURLWithPath: root, isDirectory: true)) {
            return (URL(fileURLWithPath: root, isDirectory: true), missing)
        }
        for entry in ShellEnvironment.pathEntries(environment) {
            let command = URL(fileURLWithPath: entry).appending(path: "flutter")
            guard FileManager.default.isExecutableFile(atPath: command.path) else { continue }
            // bin/flutter, possibly symlinked from Homebrew or a version manager.
            let sdk = command.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            if isSDK(sdk) { return (sdk, missing) }
        }
        return (nil, missing)
    }

    /// `frameworkVersion` from `bin/cache/flutter.version.json`, or the older `version` file.
    static func flutterVersion(_ sdk: URL) -> String? {
        if let data = try? Data(contentsOf: sdk.appending(path: "bin/cache/flutter.version.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = json["frameworkVersion"] as? String {
            return version
        }
        return (try? String(contentsOf: sdk.appending(path: "version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func pubspecName(_ pubspec: String) -> String? {
        guard let range = pubspec.range(of: #"(?m)^name:\s*(\S+)"#, options: .regularExpression) else { return nil }
        return pubspec[range].split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func buildFile(in directory: URL) -> URL? {
        ["build.gradle", "build.gradle.kts"]
            .map { directory.appending(path: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func hasBuildFile(_ directory: URL) -> Bool { buildFile(in: directory) != nil }

    /// Finds `node_modules/<name>` the way Node does: here, then each parent (monorepos hoist).
    static func findPackage(_ name: String, from directory: URL) -> URL? {
        var current = directory.standardizedFileURL
        while true {
            let candidate = current.appending(path: "node_modules/\(name)", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: candidate.appending(path: "package.json").path) { return candidate }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }
}

extension AndroidProject {
    /// Sets `sdk.dir` in `android/local.properties`, keeping any other lines.
    /// (The file is machine-specific and ignored by git in React Native templates.)
    public func writeLocalSDKDir(_ sdkPath: String) throws {
        let file = androidRootURL.appending(path: "local.properties")
        let current = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let entry = "sdk.dir=\(sdkPath)"
        var lines = current.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("sdk.dir") }) {
            lines[index] = entry
        } else {
            if lines.last == "" { lines.removeLast() }
            lines.append(entry)
            lines.append("")
        }
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}

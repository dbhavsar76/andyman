import Foundation

/// What a new app of a framework's latest stable release builds with, so setup installs
/// exactly that instead of a list that goes stale with each release.
public struct FrameworkRequirements: Sendable, Equatable, Codable {
    public enum Framework: String, Sendable, Codable, CaseIterable {
        case reactNative = "react-native"
        case flutter

        public var displayName: String {
            switch self {
            case .reactNative: "React Native"
            case .flutter: "Flutter"
            }
        }
    }

    public var framework: Framework
    /// The framework release these come from, e.g. `0.87.1`.
    public var version: String
    public var compileSdk: String
    public var buildTools: String
    public var ndk: String
    /// Only React Native builds native code in every app (the new architecture).
    public var cmake: String?
    public var minSdk: String?
    public var androidGradlePlugin: String?
    public var fetchedAt: Date
    /// Built-in values used because the latest couldn't be checked (offline, say).
    public var isFallback: Bool

    /// Values from React Native 0.87.1 and Flutter 3.47.5 (September 2026), used offline.
    public static let fallbacks: [Framework: FrameworkRequirements] = [
        .reactNative: FrameworkRequirements(
            framework: .reactNative, version: "0.87.1", compileSdk: "37", buildTools: "37.0.0",
            ndk: "27.1.12297006", cmake: AndroidGradlePlugin.defaultCMake, minSdk: "24",
            androidGradlePlugin: "9.2.1", fetchedAt: .distantPast, isFallback: true
        ),
        .flutter: FrameworkRequirements(
            framework: .flutter, version: "3.47.5", compileSdk: "36", buildTools: "36.0.0",
            ndk: "28.2.13676358", cmake: nil, minSdk: "24",
            androidGradlePlugin: "9.1.0", fetchedAt: .distantPast, isFallback: true
        ),
    ]

    public static func fallback(_ framework: Framework) -> FrameworkRequirements { fallbacks[framework]! }
}

/// Defaults the Android Gradle Plugin applies when a project doesn't set a value.
/// Read from AGP's own classes (`CMakeVersion.DEFAULT`, `ToolsRevisionUtils.DEFAULT_BUILD_TOOLS_REVISION`).
public enum AndroidGradlePlugin {
    /// The CMake version AGP 8 and 9 use when `externalNativeBuild.cmake.version` isn't set.
    public static let defaultCMake = "3.22.1"

    /// The Build Tools AGP uses when `buildToolsVersion` isn't set; nil for versions we haven't checked.
    public static func defaultBuildTools(for version: String) -> String? {
        if VersionComparator.majorVersion(version).map({ $0 >= 9 }) == true { return "36.0.0" }
        if !VersionComparator.isLess(version, "8.12") { return "35.0.0" }
        return nil
    }

    /// Whether this AGP version uses `defaultCMake` (checked for 8.x and 9.x).
    public static func usesDefaultCMake(_ version: String) -> Bool {
        guard let major = VersionComparator.majorVersion(version) else { return false }
        return major == 8 || major == 9
    }
}

/// Looks up the latest stable React Native and Flutter releases and what they build with.
///
/// - React Native: the version from npm, then that release's `gradle/libs.versions.toml`.
/// - Flutter: the stable release from Flutter's release list, then its `FlutterExtension.kt`
///   (SDK and NDK versions) and `gradle_utils.dart` (the template's Android Gradle Plugin).
///
/// Results are cached for a day; when a lookup fails, the last cached or built-in values are used.
public struct FrameworkRequirementsClient: Sendable {
    public var cacheDirectory: URL
    public var session: URLSession

    public init(cacheDirectory: URL = RepositoryClient.defaultCacheDirectory, session: URLSession = .shared) {
        self.cacheDirectory = cacheDirectory
        self.session = session
    }

    private var cacheFile: URL { cacheDirectory.appending(path: "framework-requirements.json") }

    /// Requirements for every framework. Never fails: falls back to cached, then built-in values.
    public func latest(maxAge: TimeInterval = 24 * 60 * 60, forceRefresh: Bool = false) async -> [FrameworkRequirements.Framework: FrameworkRequirements] {
        let cached = loadCache()
        var result: [FrameworkRequirements.Framework: FrameworkRequirements] = [:]
        await withTaskGroup(of: (FrameworkRequirements.Framework, FrameworkRequirements?).self) { group in
            for framework in FrameworkRequirements.Framework.allCases {
                if !forceRefresh, let entry = cached[framework], Date().timeIntervalSince(entry.fetchedAt) < maxAge {
                    result[framework] = entry
                    continue
                }
                group.addTask { (framework, try? await fetch(framework)) }
            }
            for await (framework, fetched) in group {
                result[framework] = fetched ?? cached[framework] ?? .fallback(framework)
            }
        }
        let fresh = result.values.filter { !$0.isFallback }
        if !fresh.isEmpty {
            saveCache(cached.merging(Dictionary(uniqueKeysWithValues: fresh.map { ($0.framework, $0) })) { _, new in new })
        }
        return result
    }

    /// The last fetched values, without touching the network.
    public func cached() -> [FrameworkRequirements.Framework: FrameworkRequirements] {
        var values = loadCache()
        for framework in FrameworkRequirements.Framework.allCases where values[framework] == nil {
            values[framework] = .fallback(framework)
        }
        return values
    }

    public func fetch(_ framework: FrameworkRequirements.Framework) async throws -> FrameworkRequirements {
        switch framework {
        case .reactNative:
            let latest = try await json(URL(string: "https://registry.npmjs.org/react-native/latest")!)
            guard let version = latest["version"] as? String else { throw URLError(.cannotParseResponse) }
            let toml = try await text(URL(string: "https://cdn.jsdelivr.net/npm/react-native@\(version)/gradle/libs.versions.toml")!)
            guard let requirements = Self.reactNative(version: version, toml: toml) else { throw URLError(.cannotParseResponse) }
            return requirements
        case .flutter:
            let releases = try await json(URL(string: "https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json")!)
            guard let version = Self.stableFlutterVersion(releases) else { throw URLError(.cannotParseResponse) }
            let base = "https://cdn.jsdelivr.net/gh/flutter/flutter@\(version)/packages/flutter_tools"
            async let extensionSource = text(URL(string: "\(base)/gradle/src/main/kotlin/FlutterExtension.kt")!)
            async let gradleUtils = text(URL(string: "\(base)/lib/src/android/gradle_utils.dart")!)
            guard let requirements = Self.flutter(version: version, extensionSource: try await extensionSource, gradleUtils: try? await gradleUtils) else {
                throw URLError(.cannotParseResponse)
            }
            return requirements
        }
    }

    // MARK: - Parsing

    static func reactNative(version: String, toml: String, date: Date = Date()) -> FrameworkRequirements? {
        let versions = GradleScript.catalogVersions(toml)
        guard let compileSdk = versions["compileSdk"], let buildTools = versions["buildTools"], let ndk = versions["ndkVersion"] else { return nil }
        return FrameworkRequirements(
            framework: .reactNative, version: version, compileSdk: compileSdk, buildTools: buildTools, ndk: ndk,
            cmake: AndroidGradlePlugin.defaultCMake, minSdk: versions["minSdk"], androidGradlePlugin: versions["agp"],
            fetchedAt: date, isFallback: false
        )
    }

    static func flutter(version: String, extensionSource: String, gradleUtils: String?, date: Date = Date()) -> FrameworkRequirements? {
        let defaults = FlutterDefaults.parse(extensionSource)
        guard let compileSdk = defaults.compileSdk, let ndk = defaults.ndk else { return nil }
        let agp = gradleUtils.flatMap { firstMatch(#"templateAndroidGradlePluginVersion\s*=\s*'([0-9][\w.\-]*)'"#, in: $0) }
        return FrameworkRequirements(
            framework: .flutter, version: version, compileSdk: compileSdk,
            buildTools: agp.flatMap(AndroidGradlePlugin.defaultBuildTools) ?? FrameworkRequirements.fallback(.flutter).buildTools,
            ndk: ndk, cmake: nil, minSdk: defaults.minSdk, androidGradlePlugin: agp,
            fetchedAt: date, isFallback: false
        )
    }

    /// The version of the current stable release in Flutter's `releases_macos.json`.
    static func stableFlutterVersion(_ releases: [String: Any]) -> String? {
        guard let current = releases["current_release"] as? [String: Any],
              let hash = current["stable"] as? String,
              let list = releases["releases"] as? [[String: Any]]
        else { return nil }
        return list.first { $0["hash"] as? String == hash && $0["channel"] as? String == "stable" }?["version"] as? String
    }

    private func json(_ url: URL) async throws -> [String: Any] {
        let data = try await get(url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        return object
    }

    private func text(_ url: URL) async throws -> String {
        String(decoding: try await get(url), as: UTF8.self)
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Andyman", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }

    private func loadCache() -> [FrameworkRequirements.Framework: FrameworkRequirements] {
        guard let data = try? Data(contentsOf: cacheFile),
              let list = try? JSONDecoder().decode([FrameworkRequirements].self, from: data)
        else { return [:] }
        return Dictionary(list.map { ($0.framework, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func saveCache(_ values: [FrameworkRequirements.Framework: FrameworkRequirements]) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(values.values)) {
            try? data.write(to: cacheFile, options: .atomic)
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}

/// The defaults a Flutter SDK gives app projects (`flutter.compileSdkVersion` and friends),
/// from `FlutterExtension.kt` (Flutter 3.29+) or `flutter.groovy` (older).
public struct FlutterDefaults: Sendable, Equatable {
    public var compileSdk: String?
    public var targetSdk: String?
    public var minSdk: String?
    public var ndk: String?

    public static func parse(_ source: String) -> FlutterDefaults {
        let text = GradleScript.strippingComments(source)
        func value(_ name: String) -> String? {
            // val compileSdkVersion: Int = 36 / static int compileSdkVersion = 34 / val ndkVersion: String = "28.2…"
            let pattern = #"\b\#(name)\b\s*(?::\s*\w+)?\s*=\s*"?([0-9][\w.\-]*)"?"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[range])
        }
        return FlutterDefaults(
            compileSdk: value("compileSdkVersion"),
            targetSdk: value("targetSdkVersion"),
            minSdk: value("minSdkVersion"),
            ndk: value("ndkVersion")
        )
    }

    func value(for key: GradleScript.Key) -> String? {
        switch key {
        case .compileSdk: compileSdk
        case .targetSdk: targetSdk
        case .minSdk: minSdk
        case .ndk: ndk
        case .buildTools, .cmake, .kotlin: nil
        }
    }

    /// Reads the defaults from a local Flutter SDK.
    public static func load(flutterSDK: URL) -> FlutterDefaults? {
        let candidates = [
            "packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt",
            "packages/flutter_tools/gradle/src/main/groovy/flutter.groovy",
        ]
        for path in candidates {
            if let source = try? String(contentsOf: flutterSDK.appending(path: path), encoding: .utf8) {
                let defaults = parse(source)
                if defaults.compileSdk != nil { return defaults }
            }
        }
        return nil
    }
}

import Foundation

/// Something the project doctor can fix for you.
///
/// JSON: `{"action": "install_packages", "packages": [...]}`, `{"action": "write_local_properties",
/// "sdkPath": "..."}`, `{"action": "install_jdk", "major": 17}` or `{"action": "use_jdk", "major": 17}`.
public enum ProjectFix: Sendable, Equatable, Codable {
    /// Install these SDK packages.
    case installPackages([String])
    /// Write `sdk.dir=<path>` to `android/local.properties`.
    case writeLocalProperties(sdkPath: String)
    /// Install this JDK major version (then use it for terminals).
    case installJDK(Int)
    /// This JDK version is installed; make it the one terminals (and so Gradle) use.
    case useJDK(Int)

    private enum CodingKeys: String, CodingKey { case action, packages, sdkPath, major }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .installPackages(packages):
            try container.encode("install_packages", forKey: .action)
            try container.encode(packages, forKey: .packages)
        case let .writeLocalProperties(sdkPath):
            try container.encode("write_local_properties", forKey: .action)
            try container.encode(sdkPath, forKey: .sdkPath)
        case let .installJDK(major):
            try container.encode("install_jdk", forKey: .action)
            try container.encode(major, forKey: .major)
        case let .useJDK(major):
            try container.encode("use_jdk", forKey: .action)
            try container.encode(major, forKey: .major)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .action) {
        case "install_packages": self = .installPackages(try container.decode([String].self, forKey: .packages))
        case "write_local_properties": self = .writeLocalProperties(sdkPath: try container.decode(String.self, forKey: .sdkPath))
        case "install_jdk": self = .installJDK(try container.decode(Int.self, forKey: .major))
        case "use_jdk": self = .useJDK(try container.decode(Int.self, forKey: .major))
        case let action: throw DecodingError.dataCorruptedError(forKey: .action, in: container, debugDescription: "Unknown fix \(action)")
        }
    }
}

public struct ProjectCheck: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var status: CheckStatus
    public var message: String
    public var hint: String?
    public var fix: ProjectFix?

    public init(id: String, title: String, status: CheckStatus, message: String, hint: String? = nil, fix: ProjectFix? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.message = message
        self.hint = hint
        self.fix = fix
    }
}

public struct ProjectReport: Sendable, Equatable, Codable {
    public var schemaVersion = 1
    public var project: AndroidProject
    public var status: CheckStatus
    public var checks: [ProjectCheck]
    /// The JDK Gradle will run on, and why that one.
    public var gradleJava: JavaInstallation?
    /// Environment variables read from the user's shell profile because the calling shell lacked
    /// them. Non-empty means builds from that shell need `eval "$(andyman env)"`.
    public var fromShellProfile: [String] = []
    /// Emulators that can run the app (phones and tablets at or above minSdk), closest to the
    /// target SDK first.
    public var suitableDevices: [SuitableDevice] = []

    public struct SuitableDevice: Sendable, Equatable, Codable {
        public var name: String
        public var displayName: String
        public var apiLevel: String?
        public var formFactor: VirtualDevice.FormFactor
    }

    /// SDK packages the project needs that aren't installed.
    public var missingPackages: [String] {
        checks.flatMap { check -> [String] in
            if case let .installPackages(ids) = check.fix { return ids }
            return []
        }
    }
}

/// Compares what a project needs with what's installed.
public struct ProjectDoctor: Sendable {
    public struct Input: Sendable {
        public var project: AndroidProject
        public var sdk: SDKLocation?
        public var installed: [LocalPackage]
        /// Used to pick exact package IDs (`platforms;android-37` vs `android-37.0`); optional.
        public var catalog: RepositoryCatalog?
        public var javaInstallations: [JavaInstallation]
        public var environment: [String: String]
        public var devices: [VirtualDevice]
        public var gradleUserHome: URL
        /// The JDK `/usr/bin/java` runs (what Gradle uses without JAVA_HOME), from `java_home`.
        public var defaultJava: JavaInstallation?
        /// Variables in `environment` that came from the user's shell profile (see `LoginEnvironment`).
        public var fromProfile: Set<String>

        public init(
            project: AndroidProject,
            sdk: SDKLocation?,
            installed: [LocalPackage],
            catalog: RepositoryCatalog?,
            javaInstallations: [JavaInstallation],
            environment: [String: String],
            devices: [VirtualDevice],
            gradleUserHome: URL = AndroidProject.defaultGradleUserHome,
            defaultJava: JavaInstallation? = nil,
            fromProfile: Set<String> = []
        ) {
            self.defaultJava = defaultJava
            self.fromProfile = fromProfile
            self.project = project
            self.sdk = sdk
            self.installed = installed
            self.catalog = catalog
            self.javaInstallations = javaInstallations
            self.environment = environment
            self.devices = devices
            self.gradleUserHome = gradleUserHome
        }
    }

    public init() {}

    public func check(_ input: Input) -> ProjectReport {
        let project = input.project
        var checks: [ProjectCheck] = []
        let installedIDs = Set(input.installed.map(\.id))

        if project.framework == .flutter { checks.append(flutterCheck(project)) }
        checks.append(sdkCheck(input))

        if input.sdk != nil {
            if let compileSdk = project.compileSdk {
                let candidates = Self.platformIDs(for: compileSdk.value)
                checks.append(packageCheck(
                    id: "platform", title: "Android SDK Platform \(compileSdk.value)",
                    candidates: candidates, value: compileSdk, installedIDs: installedIDs, catalog: input.catalog,
                    purpose: "compileSdk"
                ))
            }
            // Flutter apps don't set buildToolsVersion; the Android Gradle Plugin picks one.
            let buildTools = project.buildTools ?? project.androidGradlePluginVersion
                .flatMap(AndroidGradlePlugin.defaultBuildTools)
                .map { AndroidProject.Value(value: $0, source: .androidGradlePluginDefault) }
            if let buildTools {
                checks.append(packageCheck(
                    id: "build-tools", title: "Build Tools \(buildTools.value)",
                    candidates: ["build-tools;\(buildTools.value)"], value: buildTools, installedIDs: installedIDs,
                    catalog: input.catalog, purpose: "buildToolsVersion"
                ))
            }
            if let ndk = project.ndk {
                checks.append(packageCheck(
                    id: "ndk", title: "NDK \(ndk.value)",
                    candidates: ["ndk;\(ndk.value)"], value: ndk, installedIDs: installedIDs,
                    catalog: input.catalog, purpose: "ndkVersion"
                ))
            }
            if let cmake = cmakeCheck(project, installedIDs: installedIDs) { checks.append(cmake) }
        }

        let (java, javaCheck) = javaCheck(input)
        checks.append(javaCheck)
        checks.append(gradleCheck(project, gradleUserHome: input.gradleUserHome))
        if let emulator = emulatorCheck(input) { checks.append(emulator) }

        return ProjectReport(
            project: project,
            status: checks.map(\.status).max() ?? .ok,
            checks: checks,
            gradleJava: java,
            fromShellProfile: input.fromProfile.sorted(),
            suitableDevices: Self.suitableDevices(input).map {
                ProjectReport.SuitableDevice(name: $0.name, displayName: $0.displayName, apiLevel: $0.apiLevel, formFactor: $0.formFactor)
            }
        )
    }

    // MARK: - SDK

    private func sdkCheck(_ input: Input) -> ProjectCheck {
        let title = "Android SDK"
        guard let sdk = input.sdk else {
            return ProjectCheck(
                id: "sdk", title: title, status: .error,
                message: "No Android SDK found.",
                hint: "Set up Android development first."
            )
        }
        let localProperties = "android/local.properties"
        if let dir = input.project.localSDKDir {
            let expanded = ShellEnvironment.expandTilde(dir)
            if !FileManager.default.fileExists(atPath: expanded) {
                return ProjectCheck(
                    id: "sdk", title: title, status: .error,
                    message: "\(localProperties) points to \(dir), which doesn't exist.",
                    hint: "Gradle reads sdk.dir from there before ANDROID_HOME.",
                    fix: .writeLocalProperties(sdkPath: sdk.path)
                )
            }
            if !SDKLocator.Candidate.samePath(expanded, sdk.path) {
                return ProjectCheck(
                    id: "sdk", title: title, status: .warning,
                    message: "\(localProperties) uses \(dir), not \(sdk.path).",
                    hint: "Gradle builds with that SDK, so packages installed here won't be used.",
                    fix: .writeLocalProperties(sdkPath: sdk.path)
                )
            }
            return ProjectCheck(id: "sdk", title: title, status: .ok, message: "\(sdk.path) (from \(localProperties))")
        }
        let home = input.environment["ANDROID_HOME"] ?? input.environment["ANDROID_SDK_ROOT"]
        if let home, FileManager.default.fileExists(atPath: ShellEnvironment.expandTilde(home)) {
            if !SDKLocator.Candidate.samePath(ShellEnvironment.expandTilde(home), sdk.path) {
                return ProjectCheck(
                    id: "sdk", title: title, status: .warning,
                    message: "Terminals use \(home) (ANDROID_HOME), not \(sdk.path).",
                    hint: "Gradle builds with ANDROID_HOME, so packages installed here won't be used.",
                    fix: .writeLocalProperties(sdkPath: sdk.path)
                )
            }
            let variable = input.environment["ANDROID_HOME"] != nil ? "ANDROID_HOME" : "ANDROID_SDK_ROOT"
            let source: LocationSource = input.fromProfile.contains(variable) ? .shellProfile(variable) : .environment(variable)
            return ProjectCheck(
                id: "sdk", title: title, status: .ok, message: "\(sdk.path) (\(source.displayName))",
                hint: input.fromProfile.contains(variable) ? "Shells that don't load your profile don't have it. Run builds from such shells as: eval \"$(andyman env)\" && <build command>" : nil
            )
        }
        return ProjectCheck(
            id: "sdk", title: title, status: .error,
            message: "Gradle can't find the SDK: ANDROID_HOME isn't set and there's no \(localProperties).",
            hint: "Add ANDROID_HOME to your shell profile, or write local.properties for this project.",
            fix: .writeLocalProperties(sdkPath: sdk.path)
        )
    }

    /// `compileSdk 37` can be installed as `platforms;android-37` or `platforms;android-37.0`.
    static func platformIDs(for compileSdk: String) -> [String] {
        var ids = ["platforms;android-\(compileSdk)"]
        if Int(compileSdk) != nil { ids.append("platforms;android-\(compileSdk).0") }
        if compileSdk.hasSuffix(".0") { ids.append("platforms;android-\(compileSdk.dropLast(2))") }
        return ids
    }

    private func packageCheck(
        id: String,
        title: String,
        candidates: [String],
        value: AndroidProject.Value,
        installedIDs: Set<String>,
        catalog: RepositoryCatalog?,
        purpose: String
    ) -> ProjectCheck {
        let source = { (purpose: String) in Self.describe(value.source, purpose) }
        if candidates.contains(where: installedIDs.contains) {
            return ProjectCheck(id: id, title: title, status: .ok, message: "Installed · \(source(purpose))")
        }
        let installID = candidates.first { candidate in catalog?.latest(candidate, channel: .canary) != nil } ?? candidates[0]
        let size = catalog?.latest(installID, channel: .canary)?.archive?.size
        let sizeText = size.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
        return ProjectCheck(
            id: id, title: title, status: .error,
            message: "Not installed\(sizeText) · \(source(purpose))",
            hint: "Without it, Gradle downloads it mid-build, or fails if its license hasn't been accepted.",
            fix: .installPackages([installID])
        )
    }

    /// Nil when the project doesn't build native code (Flutter apps without a CMake project).
    private func cmakeCheck(_ project: AndroidProject, installedIDs: Set<String>) -> ProjectCheck? {
        let installed = installedIDs.filter { $0.hasPrefix("cmake;") }.sorted { VersionComparator.isLess($1, $0) }
        if let required = project.cmake {
            let id = "cmake;\(required.value)"
            if installedIDs.contains(id) {
                return ProjectCheck(id: "cmake", title: "CMake \(required.value)", status: .ok, message: "Installed · \(Self.describe(required.source, "version"))")
            }
            return ProjectCheck(
                id: "cmake", title: "CMake \(required.value)", status: .error,
                message: "Not installed · \(Self.describe(required.source, "version"))",
                fix: .installPackages([id])
            )
        }
        guard project.framework != .flutter else { return nil }
        // No explicit version: the Android Gradle Plugin uses its default.
        let defaultVersion = project.androidGradlePluginVersion
            .flatMap { AndroidGradlePlugin.usesDefaultCMake($0) ? AndroidGradlePlugin.defaultCMake : nil }
        if let defaultVersion {
            let id = "cmake;\(defaultVersion)"
            if installedIDs.contains(id) {
                return ProjectCheck(id: "cmake", title: "CMake \(defaultVersion)", status: .ok, message: "Installed · Android Gradle Plugin default")
            }
            return ProjectCheck(
                id: "cmake", title: "CMake \(defaultVersion)", status: .warning,
                message: "Not installed · Android Gradle Plugin default",
                hint: "Native builds (the new architecture) need it; Gradle downloads it on the first build otherwise.",
                fix: .installPackages([id])
            )
        }
        if let newest = installed.first {
            return ProjectCheck(id: "cmake", title: "CMake", status: .ok, message: "\(newest.replacingOccurrences(of: "cmake;", with: "")) installed")
        }
        return ProjectCheck(
            id: "cmake", title: "CMake", status: .warning,
            message: "None installed",
            hint: "Gradle downloads the version it needs on the first native build."
        )
    }

    /// "compileSdk set in android/build.gradle", "React Native's default compileSdk".
    static func describe(_ source: AndroidProject.Source, _ property: String) -> String {
        switch source {
        case .appBuildFile: "\(property) set in android/app/build.gradle"
        case .rootBuildFile: "\(property) set in android/build.gradle"
        case .gradleProperties: "\(property) set in android/gradle.properties"
        case .reactNativeCatalog: "React Native's default \(property)"
        case .flutterDefault: "Flutter's default \(property)"
        case .androidGradlePluginDefault: "Android Gradle Plugin default"
        }
    }

    // MARK: - Flutter

    private func flutterCheck(_ project: AndroidProject) -> ProjectCheck {
        let title = "Flutter"
        if let sdk = project.flutterSDK {
            let version = project.flutterVersion.map { "\($0) · " } ?? ""
            return ProjectCheck(id: "flutter", title: title, status: .ok, message: "\(version)\((sdk as NSString).abbreviatingWithTildeInPath)")
        }
        if let missing = project.missingFlutterSDK {
            return ProjectCheck(
                id: "flutter", title: title, status: .error,
                message: "android/local.properties points to \(missing), which isn't a Flutter SDK.",
                hint: "Run any flutter command in the project (like flutter pub get) to update it."
            )
        }
        return ProjectCheck(
            id: "flutter", title: title, status: .error,
            message: "Flutter SDK not found (not in local.properties, FLUTTER_ROOT or PATH).",
            hint: "Install Flutter, then run flutter pub get in the project, so the SDK checks can use Flutter's defaults."
        )
    }

    // MARK: - Java

    /// The JDK Gradle runs on: `org.gradle.java.home`, else `JAVA_HOME`, else the newest JDK.
    private func javaCheck(_ input: Input) -> (JavaInstallation?, ProjectCheck) {
        let project = input.project
        let title = "Java"
        var java: JavaInstallation?
        var via: String

        if let home = project.gradleJavaHome {
            java = JavaLocator.installation(at: ShellEnvironment.expandTilde(home), source: .settings)
            via = "org.gradle.java.home"
            if java == nil {
                return (nil, ProjectCheck(
                    id: "java", title: title, status: .error,
                    message: "org.gradle.java.home points to \(home), which isn't a JDK.",
                    hint: "Fix or remove it in gradle.properties (the project's or ~/.gradle/gradle.properties)."
                ))
            }
        } else if let home = input.environment["JAVA_HOME"], !home.isEmpty {
            let source: LocationSource = input.fromProfile.contains("JAVA_HOME") ? .shellProfile("JAVA_HOME") : .environment("JAVA_HOME")
            java = JavaLocator.installation(at: ShellEnvironment.expandTilde(home), source: source)
            via = source.displayName
            if java == nil {
                return (nil, ProjectCheck(
                    id: "java", title: title, status: .error,
                    message: "JAVA_HOME points to \(home), which isn't a JDK.",
                    hint: "Choose a JDK for terminals in the Java section.",
                    fix: recommendedJavaFix(input)
                ))
            }
        } else {
            // No JAVA_HOME: Gradle runs /usr/bin/java, which picks java_home's default.
            java = input.defaultJava ?? input.javaInstallations.first
            via = "no JAVA_HOME, so the macOS default from /usr/bin/java"
        }

        guard let java, let major = java.majorVersion else {
            return (nil, ProjectCheck(
                id: "java", title: title, status: .error,
                message: "No JDK found.",
                hint: "Gradle needs JDK \(JDKInstaller.recommendedMajor) or newer.",
                fix: recommendedJavaFix(input)
            ))
        }

        let gradle = project.gradleVersion
        let label = "\(java.displayName) (\(via))"
        let daemonNote = project.daemonToolchainVersion.map { " Gradle's daemon asks for JDK \($0) (gradle-daemon-jvm.properties)." } ?? ""
        switch GradleCompatibility.verdict(java: major, gradle: gradle) {
        case .supported:
            // JAVA_HOME only comes from the profile: builds from a shell that skips it get the
            // macOS default instead, which may not work.
            var hint: String?
            if java.source == .shellProfile("JAVA_HOME"), let fallback = input.defaultJava, let fallbackMajor = fallback.majorVersion {
                let verdict: String = switch GradleCompatibility.verdict(java: fallbackMajor, gradle: gradle) {
                case .supported: "."
                case .unknown: ", which Gradle \(gradle ?? "") may not support."
                case .tooNew, .tooOld: ", which Gradle \(gradle ?? "") doesn't support."
                }
                hint = "Shells that don't load your profile have no JAVA_HOME, so Gradle there would use \(fallback.displayName)" + verdict
                    + " Run builds from such shells as: eval \"$(andyman env)\" && <build command>"
            }
            return (java, ProjectCheck(id: "java", title: title, status: .ok, message: label + (daemonNote.isEmpty ? "" : "." + daemonNote), hint: hint))
        case let .tooOld(minimum):
            return (java, ProjectCheck(
                id: "java", title: title, status: .error,
                message: "\(label) is too old; the Android Gradle Plugin needs JDK \(minimum)+.",
                hint: javaHint(input),
                fix: recommendedJavaFix(input)
            ))
        case let .tooNew(maximum):
            return (java, ProjectCheck(
                id: "java", title: title, status: .error,
                message: "Gradle \(gradle ?? "") supports up to JDK \(maximum), but would run on \(label).",
                hint: javaHint(input),
                fix: recommendedJavaFix(input)
            ))
        case let .unknown(newestKnown):
            return (java, ProjectCheck(
                id: "java", title: title, status: .warning,
                message: "Gradle \(gradle ?? "") would run on \(label), which is newer than any JDK we know it supports (up to \(newestKnown)).",
                hint: javaHint(input),
                fix: recommendedJavaFix(input)
            ))
        }
    }

    /// Use the recommended JDK if it's installed, otherwise install it.
    private func recommendedJavaFix(_ input: Input) -> ProjectFix {
        let major = JDKInstaller.recommendedMajor
        return input.javaInstallations.contains { $0.majorVersion == major } ? .useJDK(major) : .installJDK(major)
    }

    private func javaHint(_ input: Input) -> String {
        let major = JDKInstaller.recommendedMajor
        let installed = input.javaInstallations.contains { $0.majorVersion == major }
        let oneOff = "For a single build: JAVA_HOME=$(/usr/libexec/java_home -v \(major)) <build command>."
        return (installed ? "JDK \(major) is installed; use it for terminals (React Native recommends it). " : "Install JDK \(major), which React Native recommends. ") + oneOff
    }

    // MARK: - Gradle & emulators

    private func gradleCheck(_ project: AndroidProject, gradleUserHome: URL) -> ProjectCheck {
        guard let version = project.gradleVersion else {
            return ProjectCheck(id: "gradle", title: "Gradle", status: .warning, message: "No Gradle wrapper (android/gradle/wrapper) found.")
        }
        let dists = gradleUserHome.appending(path: "wrapper/dists", directoryHint: .isDirectory)
        let downloaded = ["bin", "all"].contains { kind in
            let folder = dists.appending(path: "gradle-\(version)-\(kind)")
            return SDKInspector.childDirectories(of: folder).contains {
                FileManager.default.fileExists(atPath: $0.appending(path: "gradle-\(version)/bin/gradle").path)
            }
        }
        return ProjectCheck(
            id: "gradle", title: "Gradle \(version)", status: .ok,
            message: downloaded ? "Downloaded" : "Downloads on the first build"
        )
    }

    /// Phones and tablets that can run the app (a TV, watch or car image rarely suits an app
    /// project), ordered by closeness to the target SDK, then phones first.
    static func suitableDevices(_ input: Input) -> [VirtualDevice] {
        guard let minSdk = input.project.minSdk.flatMap({ Double($0.value) }) else { return [] }
        let target = input.project.targetSdk.flatMap { Double($0.value) } ?? input.project.compileSdk.flatMap { Double($0.value) }
        let handheld: [VirtualDevice.FormFactor] = [.phone, .foldable, .tablet]
        func api(_ device: VirtualDevice) -> Double { Double(device.apiLevel ?? "") ?? 0 }
        return input.devices
            .filter { $0.canLaunch && handheld.contains($0.formFactor) && api($0) >= minSdk }
            .sorted { lhs, rhs in
                let distance = { (device: VirtualDevice) in target.map { abs(api(device) - $0) } ?? -api(device) }
                if distance(lhs) != distance(rhs) { return distance(lhs) < distance(rhs) }
                return handheld.firstIndex(of: lhs.formFactor)! < handheld.firstIndex(of: rhs.formFactor)!
            }
    }

    private func emulatorCheck(_ input: Input) -> ProjectCheck? {
        guard let minSdk = input.project.minSdk.flatMap({ Double($0.value) }) else { return nil }
        let usable = Self.suitableDevices(input)
        let minText = Self.trimmed(minSdk)
        if !usable.isEmpty {
            let names = usable.map { "\($0.name) (API \($0.apiLevel ?? "?"))" }
            return ProjectCheck(id: "emulator", title: "Emulator", status: .ok, message: "Can run on \(names.joined(separator: ", ")), best match first. minSdk \(minText)")
        }
        return ProjectCheck(
            id: "emulator", title: "Emulator", status: .warning,
            message: "No phone or tablet emulator runs API \(minText) or newer.",
            hint: "Create one in the Emulators tab, or with andyman avd create."
        )
    }

    private static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

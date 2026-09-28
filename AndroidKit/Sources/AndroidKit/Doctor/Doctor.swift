import Foundation

public enum CheckStatus: String, Sendable, Codable, Comparable {
    case ok, warning, error

    private var severity: Int {
        switch self {
        case .ok: 0
        case .warning: 1
        case .error: 2
        }
    }

    public static func < (lhs: CheckStatus, rhs: CheckStatus) -> Bool { lhs.severity < rhs.severity }
}

public struct DoctorCheck: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var status: CheckStatus
    public var message: String
    /// What to do about a warning or error.
    public var hint: String?

    public init(id: String, title: String, status: CheckStatus, message: String, hint: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.message = message
        self.hint = hint
    }
}

public struct DoctorReport: Sendable, Equatable, Codable {
    public struct SDKInfo: Sendable, Equatable, Codable {
        public var location: SDKLocation?
        public var candidates: [SDKLocator.Candidate]
        public var inventory: SDKInventory?
    }

    public struct JavaInfo: Sendable, Equatable, Codable {
        public var selected: JavaInstallation?
        public var rejected: [JavaLocator.Rejection]
        public var installations: [JavaInstallation]
    }

    public struct EnvironmentInfo: Sendable, Equatable, Codable {
        public var androidHome: String?
        public var javaHome: String?
        public var adbOnPath: Bool
        public var emulatorOnPath: Bool
        /// Variables read from the user's login shell because the calling process didn't have them.
        public var fromShellProfile: [String] = []
    }

    public var schemaVersion = 1
    public var status: CheckStatus
    public var sdk: SDKInfo
    public var java: JavaInfo
    public var environment: EnvironmentInfo
    public var checks: [DoctorCheck]
}

/// Checks whether the machine is ready for Android development and explains what's missing.
public struct Doctor: Sendable {
    public struct Input: Sendable {
        /// `--sdk` from the command line.
        public var sdkFlag: String?
        public var settings: SharedPreferences
        /// The environment to judge: the CLI's own, or the app's login-shell capture.
        public var environment: [String: String]
        /// Variables in `environment` that came from the login shell, not the calling process.
        public var fromProfile: Set<String>

        public init(sdkFlag: String? = nil, settings: SharedPreferences = SharedPreferences(), environment: [String: String], fromProfile: Set<String> = []) {
            self.sdkFlag = sdkFlag
            self.settings = settings
            self.environment = environment
            self.fromProfile = fromProfile
        }
    }

    private let javaLocator: JavaLocator

    public init(javaLocator: JavaLocator = JavaLocator()) {
        self.javaLocator = javaLocator
    }

    public func run(_ input: Input) async -> DoctorReport {
        var sdkResolution = SDKLocator().resolve(
            flag: input.sdkFlag,
            settings: input.settings.sdkPathOverride,
            environment: input.environment
        )
        var javaResolution = javaLocator.resolve(
            settings: input.settings.javaHomeOverride,
            environment: input.environment,
            installations: await javaLocator.installations()
        )
        // Values the calling shell didn't have, filled in from the user's profile, say so.
        if input.fromProfile.contains("JAVA_HOME"), javaResolution.selected?.source == .environment("JAVA_HOME") {
            javaResolution.selected?.source = .shellProfile("JAVA_HOME")
        }
        if case let .environment(variable)? = sdkResolution.location?.source, input.fromProfile.contains(variable) {
            sdkResolution.location?.source = LocationSource.shellProfile(variable)
        }
        return Self.report(sdk: sdkResolution, java: javaResolution, environment: input.environment, fromProfile: input.fromProfile)
    }

    /// Builds the report from already-resolved facts. Pure, so it's easy to test.
    static func report(
        sdk: SDKLocator.Resolution,
        java: JavaLocator.Resolution,
        environment: [String: String],
        fromProfile: Set<String> = []
    ) -> DoctorReport {
        let inventory = sdk.isValid ? sdk.location.map { SDKInspector.inventory(at: $0.url) } : nil
        let path = ShellEnvironment.pathEntries(environment)
        let environmentInfo = DoctorReport.EnvironmentInfo(
            androidHome: environment["ANDROID_HOME"] ?? environment["ANDROID_SDK_ROOT"],
            javaHome: environment["JAVA_HOME"],
            adbOnPath: path.contains { FileManager.default.isExecutableFile(atPath: "\($0)/adb") },
            emulatorOnPath: path.contains { FileManager.default.isExecutableFile(atPath: "\($0)/emulator") },
            fromShellProfile: fromProfile.sorted()
        )

        var checks = [sdkCheck(sdk)]
        if let inventory {
            checks += componentChecks(inventory)
        }
        checks.append(javaCheck(java, fromProfile: fromProfile))
        checks += environmentChecks(environmentInfo, sdkPath: sdk.isValid ? sdk.location?.path : nil, fromProfile: fromProfile)

        return DoctorReport(
            status: checks.map(\.status).max() ?? .ok,
            sdk: .init(location: sdk.location, candidates: sdk.candidates, inventory: inventory),
            java: .init(selected: java.selected, rejected: java.rejected, installations: java.installations),
            environment: environmentInfo,
            checks: checks
        )
    }

    private static func sdkCheck(_ sdk: SDKLocator.Resolution) -> DoctorCheck {
        let title = "Android SDK"
        guard let location = sdk.location else {
            return DoctorCheck(
                id: "sdk.location", title: title, status: .error,
                message: "No Android SDK found.",
                hint: "Set ANDROID_HOME, choose a folder in Settings, or install one to \(SDKLocator.defaultPath)."
            )
        }
        switch sdk.selectedCandidate?.problem {
        case .missing:
            return DoctorCheck(
                id: "sdk.location", title: title, status: .error,
                message: "\(location.path) doesn't exist (\(location.source.displayName)).",
                hint: "Choose an existing SDK folder, or remove the override."
            )
        case .notAnSDK:
            return DoctorCheck(
                id: "sdk.location", title: title, status: .error,
                message: "\(location.path) doesn't look like an Android SDK (\(location.source.displayName)).",
                hint: "Pick the folder that contains platform-tools, emulator and cmdline-tools."
            )
        case nil:
            return DoctorCheck(
                id: "sdk.location", title: title, status: .ok,
                message: "\(location.path) (\(location.source.displayName))"
            )
        }
    }

    private static func componentChecks(_ inventory: SDKInventory) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        if let tools = inventory.preferredCmdlineTools {
            checks.append(DoctorCheck(
                id: "sdk.cmdline-tools", title: "Command-line Tools", status: .ok,
                message: "Version \(tools.version ?? "unknown")"
            ))
        } else {
            checks.append(DoctorCheck(
                id: "sdk.cmdline-tools", title: "Command-line Tools", status: .error,
                message: "Not installed. sdkmanager and avdmanager come from this package.",
                hint: "Install \"Android SDK Command-line Tools\" into cmdline-tools/latest."
            ))
        }
        checks.append(componentCheck(
            inventory.platformTools, id: "sdk.platform-tools", title: "Platform Tools",
            missing: "Not installed. adb comes from this package."
        ))
        checks.append(componentCheck(
            inventory.emulator, id: "sdk.emulator", title: "Emulator",
            missing: "Not installed. Needed to run virtual devices."
        ))
        return checks
    }

    private static func componentCheck(_ package: InstalledPackage?, id: String, title: String, missing: String) -> DoctorCheck {
        if let package {
            return DoctorCheck(id: id, title: title, status: .ok, message: "Version \(package.version ?? "unknown")")
        }
        return DoctorCheck(id: id, title: title, status: .warning, message: missing)
    }

    /// Shown when a value came from the shell profile because the caller's shell lacked it.
    static let profileHint = "This shell doesn't load your shell profile, so builds started from it won't see this. Prefix them with: eval \"$(andyman env)\""

    private static func javaCheck(_ java: JavaLocator.Resolution, fromProfile: Set<String>) -> DoctorCheck {
        let title = "Java"
        let minimum = JavaLocator.minimumMajorVersion
        let rejectionNote = java.rejected.first.map { rejection in
            switch rejection.reason {
            case .missing: "\(rejection.path) (\(rejection.source.displayName)) has no JDK."
            case .tooOld: "\(rejection.path) (\(rejection.source.displayName)) is older than Java \(minimum)."
            }
        }

        guard let selected = java.selected else {
            return DoctorCheck(
                id: "java", title: title, status: .error,
                message: ["No JDK \(minimum) or newer found.", rejectionNote].compactMap(\.self).joined(separator: " "),
                hint: "Install JDK 17 (recommended for React Native), e.g. from adoptium.net or Azul Zulu."
            )
        }
        let viaProfile = selected.source == .shellProfile("JAVA_HOME")
        let message = "\(selected.displayName) (\(selected.source.displayName))"
        if let rejectionNote {
            return DoctorCheck(
                id: "java", title: title, status: .warning,
                message: "\(message). \(rejectionNote)",
                hint: "Point JAVA_HOME at a JDK \(minimum)+ so Gradle uses the same one."
            )
        }
        return DoctorCheck(id: "java", title: title, status: .ok, message: message, hint: viaProfile ? profileHint : nil)
    }

    private static func environmentChecks(_ env: DoctorReport.EnvironmentInfo, sdkPath: String?, fromProfile: Set<String>) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        let exportsHint = "Add the lines from `andyman env` to your shell profile."

        switch (env.androidHome, sdkPath) {
        case (nil, _):
            checks.append(DoctorCheck(
                id: "env.android-home", title: "ANDROID_HOME", status: .warning,
                message: "Not set. React Native and Gradle use it to find the SDK.",
                hint: exportsHint
            ))
        case let (home?, sdk?) where SDKLocator.Candidate.samePath(home, sdk):
            let viaProfile = fromProfile.contains("ANDROID_HOME") || fromProfile.contains("ANDROID_SDK_ROOT")
            checks.append(DoctorCheck(
                id: "env.android-home", title: "ANDROID_HOME", status: .ok,
                message: viaProfile ? "\(home) (from your shell profile)" : home,
                hint: viaProfile ? profileHint : nil
            ))
        case let (home?, sdk?):
            checks.append(DoctorCheck(
                id: "env.android-home", title: "ANDROID_HOME", status: .warning,
                message: "Points to \(home), but the SDK in use is \(sdk).",
                hint: exportsHint
            ))
        case let (home?, nil):
            checks.append(DoctorCheck(id: "env.android-home", title: "ANDROID_HOME", status: .warning, message: "Set to \(home), which isn't a usable SDK."))
        }

        if env.adbOnPath {
            checks.append(DoctorCheck(
                id: "env.path", title: "PATH", status: .ok,
                message: fromProfile.contains("PATH") ? "adb is on PATH (in your shell profile)." : "adb is on PATH."
            ))
        } else {
            checks.append(DoctorCheck(
                id: "env.path", title: "PATH", status: .warning,
                message: "adb isn't on PATH.",
                hint: exportsHint
            ))
        }
        return checks
    }
}

extension SDKLocator.Candidate {
    public static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        func normalized(_ path: String) -> String {
            URL(fileURLWithPath: ShellEnvironment.expandTilde(path)).resolvingSymlinksInPath().standardizedFileURL.path
        }
        return normalized(lhs) == normalized(rhs)
    }
}

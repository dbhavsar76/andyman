import Foundation

/// Package sets offered by setup.
public struct SetupPreset: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var title: String
    public var detail: String
    public var packages: [String]
    /// The framework release the packages come from (React Native and Flutter presets).
    public var requirements: FrameworkRequirements?

    public init(id: String, title: String, detail: String, packages: [String], requirements: FrameworkRequirements? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.packages = packages
        self.requirements = requirements
    }

    /// The system image ABI that runs on this Mac.
    public static var hostABI: String { SystemImage.hostABIs[0] }

    public static let reactNativeID = "react-native"
    public static let flutterID = "flutter"
    public static let ids = [reactNativeID, flutterID, "minimal", "tools", "none"]

    /// What a new app of the latest React Native builds with, plus a Google Play image to run it.
    public static func reactNative(_ requirements: FrameworkRequirements = .fallback(.reactNative), catalog: RepositoryCatalog? = nil) -> SetupPreset {
        var packages = ["platform-tools", "emulator", platformID(requirements.compileSdk, catalog: catalog), "build-tools;\(requirements.buildTools)", "ndk;\(requirements.ndk)"]
        if let cmake = requirements.cmake { packages.append("cmake;\(cmake)") }
        packages.append(imageID(requirements.compileSdk, catalog: catalog))
        return SetupPreset(
            id: reactNativeID,
            title: "React Native",
            detail: "What React Native \(requirements.version) builds with: SDK \(requirements.compileSdk), Build Tools \(requirements.buildTools), NDK \(shortNDK(requirements.ndk)) and CMake \(requirements.cmake ?? "–"), plus a Google Play emulator image.",
            packages: packages,
            requirements: requirements
        )
    }

    /// What a new app of the latest Flutter builds with, plus a Google Play image to run it.
    public static func flutter(_ requirements: FrameworkRequirements = .fallback(.flutter), catalog: RepositoryCatalog? = nil) -> SetupPreset {
        SetupPreset(
            id: flutterID,
            title: "Flutter",
            detail: "What Flutter \(requirements.version) builds with: SDK \(requirements.compileSdk), Build Tools \(requirements.buildTools) and NDK \(shortNDK(requirements.ndk)), plus a Google Play emulator image. Install Flutter itself separately.",
            packages: [
                "platform-tools", "emulator", platformID(requirements.compileSdk, catalog: catalog),
                "build-tools;\(requirements.buildTools)", "ndk;\(requirements.ndk)", imageID(requirements.compileSdk, catalog: catalog),
            ],
            requirements: requirements
        )
    }

    /// The newest stable platform and its Google Play image.
    public static func minimal(catalog: RepositoryCatalog? = nil) -> SetupPreset {
        let api = newestStableAPI(catalog) ?? FrameworkRequirements.fallback(.reactNative).compileSdk
        return SetupPreset(
            id: "minimal",
            title: "Minimal",
            detail: "Platform tools, the emulator, the newest Android (API \(api)) and a Google Play image.",
            packages: ["platform-tools", "emulator", platformID(api, catalog: catalog), imageID(api, catalog: catalog)]
        )
    }

    public static var toolsOnly: SetupPreset {
        SetupPreset(
            id: "tools",
            title: "Tools Only",
            detail: "Just adb and the emulator. Add platforms and images later from the SDK tab.",
            packages: ["platform-tools", "emulator"]
        )
    }

    public static var none: SetupPreset {
        SetupPreset(id: "none", title: "None", detail: "Only the command-line tools.", packages: [])
    }

    /// The presets shown in setup, built from the latest framework requirements.
    public static func all(requirements: [FrameworkRequirements.Framework: FrameworkRequirements] = FrameworkRequirements.fallbacks, catalog: RepositoryCatalog? = nil) -> [SetupPreset] {
        [
            reactNative(requirements[.reactNative] ?? .fallback(.reactNative), catalog: catalog),
            flutter(requirements[.flutter] ?? .fallback(.flutter), catalog: catalog),
            minimal(catalog: catalog),
            toolsOnly,
        ]
    }

    public static func named(_ id: String, requirements: [FrameworkRequirements.Framework: FrameworkRequirements] = FrameworkRequirements.fallbacks, catalog: RepositoryCatalog? = nil) -> SetupPreset? {
        (all(requirements: requirements, catalog: catalog) + [none]).first { $0.id == id }
    }

    // MARK: - Package IDs

    /// `platforms;android-37` or `platforms;android-37.0`, whichever the catalog has.
    static func platformID(_ api: String, catalog: RepositoryCatalog?) -> String {
        let candidates = ProjectDoctor.platformIDs(for: api)
        return candidates.first { catalog?.latest($0) != nil } ?? candidates.last!
    }

    /// The Google Play image for an API level, for this Mac's architecture. When the catalog
    /// has none for that level yet (new platforms get images later), the newest one below it.
    static func imageID(_ api: String, catalog: RepositoryCatalog?) -> String {
        let candidates = ProjectDoctor.platformIDs(for: api).map { playImageID(platform: $0) }
        guard let catalog else { return candidates.last! }
        if let exact = candidates.first(where: { catalog.latest($0) != nil }) { return exact }
        let requested = Double(api) ?? .infinity
        let older = playImages(catalog).filter { ($0.apiNumber ?? 0) <= requested }
        return older.max(by: { ($0.apiNumber ?? 0) < ($1.apiNumber ?? 0) })?.id ?? candidates.last!
    }

    /// The newest stable platform that also has a Google Play image for this Mac.
    static func newestStableAPI(_ catalog: RepositoryCatalog?) -> String? {
        guard let catalog else { return nil }
        let imageAPIs = Set(playImages(catalog).compactMap(\.apiNumber))
        let platforms = catalog.latestPackages().filter { $0.category == .platforms && !$0.isPreview }
        guard let newest = platforms.filter({ imageAPIs.contains($0.apiNumber ?? -1) }).max(by: { ($0.apiNumber ?? 0) < ($1.apiNumber ?? 0) }),
              let api = newest.apiNumber
        else { return nil }
        return api == api.rounded() ? String(Int(api)) : String(api)
    }

    private static func playImageID(platform: String) -> String {
        platform.replacingOccurrences(of: "platforms;", with: "system-images;") + ";google_apis_playstore;\(hostABI)"
    }

    private static func playImages(_ catalog: RepositoryCatalog) -> [RemotePackage] {
        catalog.latestPackages().filter {
            $0.category == .systemImages && !$0.isPreview && $0.id.hasSuffix(";google_apis_playstore;\(hostABI)")
        }
    }

    /// `27.1.12297006` → `27.1`
    static func shortNDK(_ version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }
}

public struct SetupOptions: Sendable, Equatable, Codable {
    public var sdkPath: String
    /// JDK major version to install if there's no JDK 17+; nil to skip.
    public var jdkMajor: Int?
    public var packages: [String]
    public var createEmulator: Bool
    public var emulatorProfile: String
    public var writeShellProfile: Bool
    public var shell: ShellExports.Shell

    public init(
        sdkPath: String = SDKLocator.defaultPath,
        jdkMajor: Int? = JDKInstaller.recommendedMajor,
        packages: [String] = SetupPreset.reactNative().packages,
        createEmulator: Bool = true,
        emulatorProfile: String = "medium_phone",
        writeShellProfile: Bool = false,
        shell: ShellExports.Shell = .zsh
    ) {
        self.sdkPath = sdkPath
        self.jdkMajor = jdkMajor
        self.packages = packages
        self.createEmulator = createEmulator
        self.emulatorProfile = emulatorProfile
        self.writeShellProfile = writeShellProfile
        self.shell = shell
    }

    public var sdkRoot: URL { URL(fileURLWithPath: ShellEnvironment.expandTilde(sdkPath), isDirectory: true).standardizedFileURL }

    /// The image the first emulator runs: the first system image in `packages`.
    public var emulatorImage: String? { packages.first { $0.hasPrefix("system-images;") } }
}

public enum SetupStep: String, Sendable, Codable, CaseIterable {
    case jdk, commandLineTools = "command_line_tools", packages, emulator, shellProfile = "shell_profile", verify

    public var title: String {
        switch self {
        case .jdk: "Java"
        case .commandLineTools: "Command-line Tools"
        case .packages: "SDK Packages"
        case .emulator: "Emulator"
        case .shellProfile: "Shell Profile"
        case .verify: "Check"
        }
    }
}

public enum SetupEvent: Sendable, Equatable {
    case started(SetupStep)
    case progress(SetupStep, received: Int64, total: Int64)
    /// A short status line, e.g. "Unpacking…" or "Installing NDK (Side by side) 27.1".
    case detail(SetupStep, String)
    case finished(SetupStep, summary: String)
    case skipped(SetupStep, reason: String)
}

/// What setup will do, worked out before anything is downloaded.
public struct SetupPlan: Sendable, Equatable {
    public var steps: [SetupStep]
    public var jdk: JDKRelease?
    public var bootstrapTools: Bool
    /// Download size of the command-line tools (0 when they're already installed).
    public var toolsSize: Int64 = 0
    public var install: InstallPlan
    public var licenses: [SDKLicense]
    /// Licenses not yet accepted in this SDK; setup needs them accepted before it starts.
    public var unacceptedLicenses: [SDKLicense]
    public var downloadSize: Int64
    public var existingJava: JavaInstallation?
    public var createEmulator: Bool
    public var shellChange: ShellProfileEditor.Change?
}

public struct SetupResult: Sendable, Equatable {
    public var java: JavaInstallation?
    public var emulator: VirtualDevice?
    public var shellBackup: URL?
    public var report: DoctorReport
}

public enum SetupError: Error, Sendable, Equatable, LocalizedError {
    case licensesNotAccepted([String])

    public var errorDescription: String? {
        switch self {
        case let .licensesNotAccepted(ids): "These licenses need to be accepted first: \(ids.joined(separator: ", "))."
        }
    }
}

/// Sets up Android development from nothing (or fills in what's missing): JDK, command-line
/// tools, SDK packages, a first emulator and the shell environment.
public struct EnvironmentSetup: Sendable {
    public var environment: [String: String]
    public var jdkDestination: URL
    private let javaLocator = JavaLocator()

    public init(environment: [String: String], jdkDestination: URL = JDKInstaller.defaultDestination) {
        self.environment = environment
        self.jdkDestination = jdkDestination
    }

    // MARK: - Planning

    public func plan(_ options: SetupOptions, catalog: RepositoryCatalog) async throws -> SetupPlan {
        let sdkRoot = options.sdkRoot
        let java = await existingJava()
        var steps: [SetupStep] = []

        var jdk: JDKRelease?
        if java == nil, let major = options.jdkMajor {
            jdk = try await JDKInstaller(destination: jdkDestination).latestRelease(major: major)
            steps.append(.jdk)
        }

        let bootstrap = CommandLineToolsBootstrap(sdkRoot: sdkRoot).isNeeded
        if bootstrap { steps.append(.commandLineTools) }

        let installed = LocalPackages.scan(sdkRoot: sdkRoot)
        let install = try catalog.installPlan(for: options.packages, installed: installed)
        if !install.isEmpty { steps.append(.packages) }

        // Creating an AVD runs avdmanager, a Java tool: only possible with a JDK.
        let createEmulator = options.createEmulator && options.emulatorImage != nil && (java != nil || jdk != nil)
        if createEmulator { steps.append(.emulator) }

        var shellChange: ShellProfileEditor.Change?
        if options.writeShellProfile {
            let lines = ShellExports.lines(sdkPath: sdkRoot.path, java: java ?? jdk.map(Self.placeholderJava), shell: options.shell)
            let change = ShellProfileEditor(shell: options.shell).proposedChange(lines: lines)
            if change.isNeeded {
                shellChange = change
                steps.append(.shellProfile)
            }
        }
        steps.append(.verify)

        // Everything the tools bootstrap and package installs need accepted.
        var licenseIDs = Set(install.licenses.map(\.id))
        if bootstrap, let license = catalog.latest(CommandLineToolsBootstrap.packageID)?.licenseID { licenseIDs.insert(license) }
        let licenses = licenseIDs.sorted().compactMap { catalog.licenses[$0] }
        let accepted = LicenseStore(sdkRoot: sdkRoot).acceptedIDs

        let toolsSize = bootstrap ? (catalog.latest(CommandLineToolsBootstrap.packageID)?.archive?.size ?? 0) : 0
        return SetupPlan(
            steps: steps,
            jdk: jdk,
            bootstrapTools: bootstrap,
            toolsSize: toolsSize,
            install: install,
            licenses: licenses,
            unacceptedLicenses: licenses.filter { !accepted.contains($0.id) },
            downloadSize: (jdk?.size ?? 0) + toolsSize + install.downloadSize,
            existingJava: java,
            createEmulator: createEmulator,
            shellChange: shellChange
        )
    }

    /// A JDK 17+ that's already installed, if any.
    func existingJava() async -> JavaInstallation? {
        javaLocator.resolve(
            settings: SharedPreferences().javaHomeOverride,
            environment: environment,
            installations: await javaLocator.installations()
        ).selected
    }

    /// Stand-in for a JDK that's about to be installed, so the shell lines can be previewed.
    static func placeholderJava(_ release: JDKRelease) -> JavaInstallation {
        JavaInstallation(home: "", version: release.version, vendor: "Eclipse Adoptium", name: "Eclipse Temurin \(release.major)", source: .javaHomeTool)
    }

    // MARK: - Running

    /// Runs a plan. Licenses in `plan.unacceptedLicenses` must have been accepted (by the user)
    /// before calling this.
    public func run(
        _ plan: SetupPlan,
        options: SetupOptions,
        catalog: RepositoryCatalog,
        events: @escaping @Sendable (SetupEvent) -> Void
    ) async throws -> SetupResult {
        let sdkRoot = options.sdkRoot
        let licenses = LicenseStore(sdkRoot: sdkRoot)
        let missing = plan.licenses.filter { !licenses.isAccepted($0.id) }
        guard missing.isEmpty else { throw SetupError.licensesNotAccepted(missing.map(\.id)) }
        try FileManager.default.createDirectory(at: sdkRoot, withIntermediateDirectories: true)

        // 1. Java
        var java = plan.existingJava
        if let release = plan.jdk {
            events(.started(.jdk))
            let installed = try await JDKInstaller(destination: jdkDestination).install(release) { received, total in
                events(.progress(.jdk, received: received, total: total))
            } extracting: {
                events(.detail(.jdk, "Unpacking…"))
            }
            java = installed
            events(.finished(.jdk, summary: "Installed Eclipse Temurin \(release.version)"))
        }

        // 2. Command-line tools
        if plan.bootstrapTools {
            events(.started(.commandLineTools))
            try await CommandLineToolsBootstrap(sdkRoot: sdkRoot).install(from: catalog) { received, total in
                events(.progress(.commandLineTools, received: received, total: total))
            } extracting: {
                events(.detail(.commandLineTools, "Unpacking…"))
            }
            let version = catalog.latest(CommandLineToolsBootstrap.packageID).map { "\($0.revision)" } ?? ""
            events(.finished(.commandLineTools, summary: "Installed version \(version)"))
        }

        // 3. Packages (the plan is recomputed: the tools may have changed what's installed)
        if plan.steps.contains(.packages) {
            events(.started(.packages))
            let install = try catalog.installPlan(for: options.packages, installed: LocalPackages.scan(sdkRoot: sdkRoot))
            let names = Dictionary(uniqueKeysWithValues: install.packages.map { ($0.id, $0.displayName) })
            let sizes = Dictionary(uniqueKeysWithValues: install.packages.map { ($0.id, $0.archive?.size ?? 0) })
            let total = sizes.values.reduce(0, +)
            var completed: Int64 = 0
            let installer = SDKInstaller(sdkRoot: sdkRoot, java: java, environment: environment)
            for try await event in installer.install(install) {
                switch event {
                case let .started(id):
                    events(.detail(.packages, "Installing \(names[id] ?? id)"))
                case let .downloading(_, received, _):
                    events(.progress(.packages, received: completed + received, total: total))
                case let .unpacking(id):
                    events(.detail(.packages, "Unpacking \(names[id] ?? id)"))
                case let .finished(id):
                    completed += sizes[id] ?? 0
                    events(.progress(.packages, received: completed, total: total))
                case .output:
                    break
                }
            }
            events(.finished(.packages, summary: "Installed \(install.packages.count) package\(install.packages.count == 1 ? "" : "s")"))
        }

        // 4. First emulator
        var emulator: VirtualDevice?
        if plan.createEmulator, let image = options.emulatorImage {
            events(.started(.emulator))
            let catalog = AVDCatalog(directory: AVDCatalog.defaultDirectory(environment: environment), sdkRoot: sdkRoot)
            let systemImage = SystemImages.installed(in: sdkRoot).first { $0.id == image }
            let profile = DeviceProfile(
                id: options.emulatorProfile, name: "Medium Phone", manufacturer: "Generic", category: .phone,
                isLegacy: false, isUserDefined: false, diagonalInches: nil, screenWidth: nil, screenHeight: nil,
                density: nil, ramMB: nil, skin: nil, tagID: nil, minAPILevel: nil, playStore: true, hasHinge: false
            )
            let name = systemImage.map { catalog.suggestedName(profile: profile, image: $0) } ?? "Medium_Phone"
            let apiLevel = systemImage?.apiLevel ?? ""
            emulator = try await catalog.create(
                AVDSpec(name: name, profileID: options.emulatorProfile, systemImage: image, settings: AVDSettings(displayName: "Medium Phone API \(apiLevel)")),
                java: java,
                environment: environment
            )
            events(.finished(.emulator, summary: "Created \(emulator?.displayName ?? name)"))
        }

        // 5. Shell profile
        var backup: URL?
        if plan.shellChange != nil {
            events(.started(.shellProfile))
            let lines = ShellExports.lines(sdkPath: sdkRoot.path, java: java, shell: options.shell)
            let editor = ShellProfileEditor(shell: options.shell)
            backup = try editor.apply(lines: lines)
            events(.finished(.shellProfile, summary: "Updated \(options.shell.profilePath)"))
        }

        // 6. Check the result as a new terminal would see it.
        events(.started(.verify))
        var checkEnvironment = environment
        checkEnvironment["ANDROID_HOME"] = sdkRoot.path
        if let java { checkEnvironment["JAVA_HOME"] = java.home }
        checkEnvironment["PATH"] = (checkEnvironment["PATH"] ?? "/usr/bin:/bin") + ":\(sdkRoot.path)/platform-tools:\(sdkRoot.path)/emulator"
        let report = await Doctor().run(.init(sdkFlag: sdkRoot.path, environment: checkEnvironment))
        let acceleration = await accelerationCheck(sdkRoot: sdkRoot)
        let problems = report.checks.filter { $0.status == .error }.count
        events(.finished(.verify, summary: problems == 0 ? "Ready\(acceleration.map { " · \($0)" } ?? "")" : "\(problems) problem(s) left; see Tools"))

        return SetupResult(java: java, emulator: emulator, shellBackup: backup, report: report)
    }

    /// Asks the emulator whether hardware acceleration works (Hypervisor.framework on macOS).
    func accelerationCheck(sdkRoot: URL) async -> String? {
        let emulator = sdkRoot.appending(path: "emulator/emulator")
        guard FileManager.default.isExecutableFile(atPath: emulator.path),
              let result = try? await ProcessRunner().run(emulator, arguments: ["-accel-check"], timeout: .seconds(20))
        else { return nil }
        return result.succeeded ? "hardware acceleration available" : "hardware acceleration unavailable"
    }
}

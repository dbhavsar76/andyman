import AndroidKit
import AppKit
import Observation

/// App-wide state: the resolved environment and user overrides.
@Observable
final class AppModel {
    let emulators = EmulatorStore()
    let sdk = SDKStore()
    let setup = SetupStore()
    let projects = ProjectStore()
    let maintenance = MaintenanceStore()
    let java = JavaStore()
    let agents = AgentsStore()
    private(set) var report: DoctorReport?
    private(set) var isRefreshing = false
    private(set) var sdkPathOverride: String?
    private(set) var javaHomeOverride: String?

    /// The login shell's environment, captured once (apps launched from Finder don't inherit it).
    private var shellEnvironment: [String: String]?
    private let preferences = SharedPreferences()

    init() {
        sdkPathOverride = preferences.sdkPathOverride
        javaHomeOverride = preferences.javaHomeOverride
        setup.onFinished = { [weak self] in self?.setupDidFinish() }
        java.onInstalled = { [weak self] in
            Task { await self?.refresh() }
        }
    }

    /// After setup, remember a custom SDK location (so it's found even without ANDROID_HOME),
    /// then re-read everything, including the shell profile it may have edited.
    private func setupDidFinish() {
        let path = setup.options.sdkRoot.path
        let automatic = SDKLocator().resolve(environment: environment).location?.path
        let alreadySet = sdkPathOverride.map { SDKLocator.Candidate.samePath($0, path) } ?? false
        if automatic.map({ !SDKLocator.Candidate.samePath($0, path) }) ?? true, !alreadySet {
            preferences.sdkPathOverride = path
            sdkPathOverride = path
        }
        Task { await refresh(reloadShell: true) }
    }

    /// Process environment overlaid with the login shell's, so `ANDROID_HOME` from `~/.zshrc` counts.
    var environment: [String: String] {
        ProcessInfo.processInfo.environment.merging(shellEnvironment ?? [:]) { _, shell in shell }
    }

    var shell: ShellExports.Shell { ShellExports.Shell(shellPath: environment["SHELL"]) }

    /// Re-runs the doctor. Pass `reloadShell` after the user may have edited their dotfiles.
    func refresh(reloadShell: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if shellEnvironment == nil || reloadShell {
            shellEnvironment = await ShellEnvironment.capture()
        }
        let report = await Doctor().run(.init(settings: preferences, environment: environment))
        self.report = report
        let hasAVDs = !AVDCatalog(directory: AVDCatalog.defaultDirectory(environment: environment), sdkRoot: nil).scan().devices.isEmpty
        setup.configure(report: report, environment: environment, shell: shell, hasAVDs: hasAVDs)
        sdk.configure(
            sdk: report.sdk.inventory == nil ? nil : report.sdk.location,
            java: report.java.selected,
            environment: environment
        )
        emulators.configure(
            sdk: report.sdk.inventory == nil ? nil : report.sdk.location,
            inventory: report.sdk.inventory,
            java: report.java.selected,
            environment: environment
        )
        defaultJava = await JavaLocator().systemDefault()
        await agents.refresh(environment: environment)
    }

    func setSDKPathOverride(_ path: String?) {
        preferences.sdkPathOverride = path
        sdkPathOverride = preferences.sdkPathOverride
        Task { await refresh() }
    }

    func setJavaHomeOverride(_ home: String?) {
        preferences.javaHomeOverride = home
        javaHomeOverride = preferences.javaHomeOverride
        Task { await refresh() }
    }

    // MARK: - Tools

    /// Everything the project doctor compares a project against.
    var projectContext: ProjectContext {
        ProjectContext(
            sdk: report?.sdk.inventory == nil ? nil : report?.sdk.location,
            installed: sdk.installed,
            catalog: sdk.catalog,
            javaInstallations: report?.java.installations ?? [],
            environment: environment,
            devices: emulators.devices,
            defaultJava: defaultJava
        )
    }

    /// The JDK `/usr/bin/java` runs (what Gradle uses without JAVA_HOME).
    private(set) var defaultJava: JavaInstallation?

    func scanCleanup() async {
        await maintenance.scan(
            sdkRoot: report?.sdk.location?.url,
            environment: environment,
            devices: emulators.devices,
            running: Set(emulators.running.map(\.avdName))
        )
    }

    func cleanSelected() async {
        await maintenance.cleanSelected(
            sdkRoot: report?.sdk.location?.url,
            environment: environment,
            devices: emulators.devices,
            running: Set(emulators.running.map(\.avdName))
        )
    }

    /// The shell profile block that sets `ANDROID_HOME`, `PATH` and `JAVA_HOME` (to `java`,
    /// or the JDK in use).
    func shellProfileChange(java: JavaInstallation? = nil) -> ShellProfileEditor.Change {
        let lines = ShellExports.lines(sdkPath: report?.sdk.location?.path, java: java ?? report?.java.selected, shell: shell)
        return ShellProfileEditor(shell: shell).proposedChange(lines: lines)
    }

    /// Writes the block to the shell profile (backed up first), re-reads the login shell and
    /// checks that terminals now see it. Returns a problem to show, if any.
    func writeShellProfile(java: JavaInstallation? = nil) async -> String? {
        let lines = ShellExports.lines(sdkPath: report?.sdk.location?.path, java: java ?? report?.java.selected, shell: shell)
        do {
            try ShellProfileEditor(shell: shell).apply(lines: lines)
        } catch {
            return "Couldn't update \(shell.profilePath): \(error.localizedDescription)"
        }
        await refresh(reloadShell: true)
        // Something later in the profile can override the block; say so rather than pretend.
        if let java, !Self.sameJDK(environment["JAVA_HOME"], java.home) {
            return "\(shell.profilePath) sets JAVA_HOME again after the Andyman block, so terminals still use \(environment["JAVA_HOME"] ?? "another JDK"). Remove that line to use \(java.displayName)."
        }
        return nil
    }

    static func sameJDK(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        let resolve = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
        return resolve(lhs) == resolve(rhs)
    }

    func copyShellExports() {
        guard let report else { return }
        let lines = ShellExports.lines(sdkPath: report.sdk.location?.path, java: report.java.selected, shell: shell)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n") + "\n", forType: .string)
    }
}

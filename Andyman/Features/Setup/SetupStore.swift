import AndroidKit
import Foundation
import Observation

/// Drives "Set Up Android Development": options, the plan, and the running steps.
@Observable
final class SetupStore {
    enum Phase: Equatable {
        case configuring
        case running
        case finished
        case failed(String)
    }

    enum StepState: Equatable {
        case pending
        case running(detail: String?, fraction: Double?)
        case done(String)
    }

    // Options
    var sdkPath: String = SDKLocator.defaultPath { didSet { replan() } }
    var presetID = SetupPreset.reactNativeID { didSet { replan() } }
    var jdkMajor = JDKInstaller.recommendedMajor { didSet { replan() } }
    var createEmulator = true { didSet { replan() } }
    var writeShellProfile = true { didSet { replan() } }

    private(set) var phase: Phase = .configuring
    private(set) var plan: SetupPlan?
    private(set) var isPlanning = false
    private(set) var planError: String?
    private(set) var steps: [SetupStep: StepState] = [:]
    private(set) var result: SetupResult?
    /// Licenses waiting for the user before setup can start.
    private(set) var pendingLicenses: [SDKLicense] = []
    /// What the latest React Native and Flutter build with (cached or built-in until checked).
    private(set) var requirements = FrameworkRequirementsClient().cached()
    private var checkedRequirements = false

    private var environment: [String: String] = [:]
    private var shell: ShellExports.Shell = .zsh
    private(set) var catalog: RepositoryCatalog?
    private var planTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var configured = false
    var onFinished: () -> Void = {}

    /// Presets built from the latest framework requirements and the package catalog.
    var presets: [SetupPreset] { SetupPreset.all(requirements: requirements, catalog: catalog) }
    var preset: SetupPreset { presets.first { $0.id == presetID } ?? presets[0] }
    var shellProfilePath: String { shell.profilePath }
    var isRunning: Bool { phase == .running }

    var options: SetupOptions {
        SetupOptions(
            sdkPath: sdkPath,
            jdkMajor: jdkMajor,
            packages: preset.packages,
            createEmulator: createEmulator,
            writeShellProfile: writeShellProfile,
            shell: shell
        )
    }

    /// Overall progress (0…1) while running, for the menu bar icon.
    var progress: Double? {
        guard phase == .running, let plan, !plan.steps.isEmpty else { return nil }
        let perStep = 1.0 / Double(plan.steps.count)
        return plan.steps.reduce(0) { sum, step in
            switch steps[step] {
            case .done: sum + perStep
            case let .running(_, fraction): sum + perStep * (fraction ?? 0)
            default: sum
            }
        }
    }

    /// Picks sensible defaults from what's already on the Mac (first call only).
    func configure(report: DoctorReport?, environment: [String: String], shell: ShellExports.Shell, hasAVDs: Bool) {
        self.environment = environment
        self.shell = shell
        guard !configured, !isRunning else { return }
        configured = true
        if let location = report?.sdk.location { sdkPath = location.path }
        createEmulator = !hasAVDs
        writeShellProfile = !ShellProfileEditor.isConfigured(environment: environment, sdkPath: sdkPath)
    }

    // MARK: - Planning

    /// Recomputes the plan after options change (coalesced).
    func replan() {
        guard phase == .configuring || phase == .finished || isFailed else { return }
        planTask?.cancel()
        planTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await makePlan()
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    func makePlan() async {
        isPlanning = true
        defer { isPlanning = false }
        do {
            if !checkedRequirements {
                async let latest = FrameworkRequirementsClient().latest()
                if catalog == nil { catalog = try await RepositoryClient().catalog() }
                requirements = await latest
                checkedRequirements = true
            } else if catalog == nil {
                catalog = try await RepositoryClient().catalog()
            }
            guard let catalog else { return }
            let options = options
            plan = try await EnvironmentSetup(environment: environment).plan(options, catalog: catalog)
            planError = nil
        } catch is CancellationError {
        } catch {
            planError = error.localizedDescription
        }
    }

    // MARK: - Running

    /// Starts setup. Returns true if licenses need reviewing first (the UI shows them).
    @discardableResult
    func start() -> Bool {
        guard let plan else { return false }
        if !plan.unacceptedLicenses.isEmpty {
            pendingLicenses = plan.unacceptedLicenses
            return true
        }
        run(plan)
        return false
    }

    func acceptLicensesAndStart() {
        guard let plan else { return }
        do {
            try FileManager.default.createDirectory(at: options.sdkRoot, withIntermediateDirectories: true)
            let store = LicenseStore(sdkRoot: options.sdkRoot)
            for license in pendingLicenses { try store.accept(license) }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        pendingLicenses = []
        run(plan)
    }

    func declineLicenses() {
        pendingLicenses = []
    }

    private func run(_ plan: SetupPlan) {
        guard let catalog else { return }
        phase = .running
        Notifier.shared.requestAuthorization()
        steps = Dictionary(uniqueKeysWithValues: plan.steps.map { ($0, StepState.pending) })
        result = nil
        let options = options
        let setup = EnvironmentSetup(environment: environment)
        runTask = Task {
            do {
                let result = try await setup.run(plan, options: options, catalog: catalog) { event in
                    // The store lives as long as the app, so a strong capture is fine.
                    Task { @MainActor in self.handle(event) }
                }
                // Let queued step events land before switching to the summary.
                try? await Task.sleep(for: .milliseconds(100))
                self.result = result
                phase = .finished
                onFinished()
                Notifier.shared.post("Android setup finished", "Your Mac is ready for Android development.", opening: .setup)
            } catch is CancellationError {
                phase = .configuring
                await makePlan()
            } catch {
                phase = .failed(error.localizedDescription)
                Notifier.shared.post("Android setup failed", error.localizedDescription, opening: .setup)
            }
            runTask = nil
        }
    }

    private func handle(_ event: SetupEvent) {
        switch event {
        case let .started(step):
            steps[step] = .running(detail: nil, fraction: nil)
        case let .progress(step, received, total):
            let detail = "\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
            let current = steps[step]
            if case let .running(existing, _) = current, let existing, !existing.contains(" of ") {
                steps[step] = .running(detail: existing, fraction: total > 0 ? Double(received) / Double(total) : nil)
            } else {
                steps[step] = .running(detail: detail, fraction: total > 0 ? Double(received) / Double(total) : nil)
            }
        case let .detail(step, text):
            var fraction: Double?
            if case let .running(_, existing) = steps[step] { fraction = existing }
            steps[step] = .running(detail: text, fraction: fraction)
        case let .finished(step, summary):
            steps[step] = .done(summary)
        case let .skipped(step, reason):
            steps[step] = .done(reason)
        }
    }

    func cancel() {
        runTask?.cancel()
    }

    /// Back to the options, e.g. to run setup again with different choices.
    func reset() {
        phase = .configuring
        result = nil
        steps = [:]
        replan()
    }
}

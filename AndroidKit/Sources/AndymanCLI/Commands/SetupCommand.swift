import AndroidKit
import ArgumentParser
import Foundation

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Set up Android development from scratch, or fill in what's missing.",
        discussion: """
        Installs a JDK if there's no JDK 17+, the SDK command-line tools, a package preset, and \
        creates a first emulator. Steps that are already done are skipped, so it's safe to rerun.

        Presets: react-native (default), flutter, minimal, tools, none. The react-native and \
        flutter presets follow each framework's latest stable release (checked online daily, \
        with built-in values offline). Add packages with --package.
        Use --dry-run to see the plan (steps, downloads, licenses) without changing anything.
        Needs --accept-licenses unless the SDK licenses were accepted before.
        With --json, prints one JSON object per line (plan, started, progress, detail, finished) \
        and ends with a `done` event.
        """
    )

    @OptionGroup var options: GlobalOptions
    @Option(help: "Package preset: react-native, flutter, minimal, tools or none.") var preset = SetupPreset.reactNativeID
    @Option(name: .customLong("package"), help: "Extra package to install (repeatable).") var extraPackages: [String] = []
    @Option(help: ArgumentHelp("Where the SDK goes. Defaults to the current SDK, or ~/Library/Android/sdk.", valueName: "path"))
    var sdkPath: String?
    @Option(help: "JDK version to install if there's no JDK 17+: 17 or 21.") var jdk = JDKInstaller.recommendedMajor
    @Flag(help: "Don't install a JDK.") var noJdk = false
    @Flag(help: "Don't create an emulator.") var noEmulator = false
    @Flag(help: "Add ANDROID_HOME, JAVA_HOME and PATH to your shell profile (backed up first).") var writeShellProfile = false
    @Flag(help: "Accept the licenses of everything being installed.") var acceptLicenses = false
    @Flag(help: "Show the plan without installing anything.") var dryRun = false

    func validate() throws {
        guard SetupPreset.ids.contains(preset) else { throw ValidationError("Unknown preset \(preset). Use \(SetupPreset.ids.joined(separator: ", ")).") }
        guard JDKInstaller.offeredMajors.contains(jdk) else { throw ValidationError("--jdk must be one of \(JDKInstaller.offeredMajors.map(String.init).joined(separator: ", ")).") }
    }

    func run() async throws {
        let context = CommandContext(options)
        let catalog = try await context.catalog()
        let requirements = await FrameworkRequirementsClient().latest()
        let chosen = SetupPreset.named(preset, requirements: requirements, catalog: catalog)!
        let setupOptions = SetupOptions(
            sdkPath: sdkPath ?? options.sdk ?? context.sdk?.path ?? SDKLocator.defaultPath,
            jdkMajor: noJdk ? nil : jdk,
            packages: chosen.packages + extraPackages.map(SDKPackageID.normalize),
            createEmulator: !noEmulator && !hasAnyAVD(context),
            writeShellProfile: writeShellProfile,
            shell: ShellExports.Shell(shellPath: context.environment["SHELL"])
        )
        let setup = EnvironmentSetup(environment: context.environment)

        let plan: SetupPlan
        do {
            plan = try await setup.plan(setupOptions, catalog: catalog)
        } catch {
            throw CLIError(sdkError: error)
        }

        let reporter = SetupReporter(json: options.json)
        reporter.planned(plan, options: setupOptions, preset: chosen)
        if dryRun {
            reporter.dryRunDone(plan)
            return
        }

        if !plan.unacceptedLicenses.isEmpty {
            guard acceptLicenses else {
                throw CLIError(
                    code: "license_not_accepted",
                    message: "Setup needs licenses that haven't been accepted: \(plan.unacceptedLicenses.map(\.id).joined(separator: ", ")).",
                    hint: "Review them with `andyman licenses show <id>`, then rerun with --accept-licenses.",
                    exitStatus: .licenseRequired
                )
            }
            try FileManager.default.createDirectory(at: setupOptions.sdkRoot, withIntermediateDirectories: true)
            let store = LicenseStore(sdkRoot: setupOptions.sdkRoot)
            for license in plan.unacceptedLicenses { try store.accept(license) }
        }

        let result: SetupResult
        do {
            result = try await setup.run(plan, options: setupOptions, catalog: catalog) { reporter.handle($0) }
        } catch {
            throw CLIError(sdkError: error)
        }
        reporter.done(result, options: setupOptions)
    }

    private func hasAnyAVD(_ context: CommandContext) -> Bool {
        !context.catalog.scan().devices.isEmpty
    }
}

private final class SetupReporter: @unchecked Sendable {
    let json: Bool
    private let lock = NSLock()
    private var lastPercent: [SetupStep: Int] = [:]
    private let interactive = isatty(STDERR_FILENO) == 1

    init(json: Bool) {
        self.json = json
    }

    private func emit(_ object: [String: Any]) {
        var object = object
        object["schemaVersion"] = Output.schemaVersion
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) {
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
    }

    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    func planned(_ plan: SetupPlan, options: SetupOptions, preset: SetupPreset) {
        if json {
            emit([
                "event": "plan",
                "preset": preset.id,
                "framework": preset.requirements.map { ["name": $0.framework.rawValue, "version": $0.version, "latestChecked": !$0.isFallback] } as Any,
                "sdkPath": options.sdkRoot.path,
                "steps": plan.steps.map(\.rawValue),
                "jdk": plan.jdk.map { $0.name } as Any,
                "existingJava": plan.existingJava?.home as Any,
                "packages": plan.install.packages.map(\.id),
                "packageDetails": plan.install.packages.map { ["id": $0.id, "displayName": $0.displayName, "size": $0.archive?.size as Any] },
                "toolsSize": plan.toolsSize,
                "downloadSize": plan.downloadSize,
                "licenses": plan.licenses.map(\.id),
                "unacceptedLicenses": plan.unacceptedLicenses.map(\.id),
                "createEmulator": plan.createEmulator,
            ])
            return
        }
        let style = Style.current
        Output.line(style.bold("Setting up Android development in \(options.sdkRoot.path)"))
        if let requirements = preset.requirements {
            let note = requirements.isFallback ? style.yellow("built-in; couldn't check for a newer release") : style.dim("latest stable")
            Output.line("  Preset              \(preset.title) \(requirements.version) (\(note))")
        }
        if let java = plan.existingJava {
            Output.line("  Java                \(style.dim("already installed: \(java.displayName)"))")
        } else if let jdk = plan.jdk {
            Output.line("  Java                Eclipse Temurin \(jdk.version) (\(size(jdk.size)))")
        } else {
            Output.line("  Java                \(style.yellow("none (skipped); emulators can't be created without one"))")
        }
        Output.line("  Command-line Tools  " + (plan.bootstrapTools ? "download (\(size(plan.toolsSize)))" : style.dim("already installed")))
        let packages = plan.install.packages.map { package in
            package.id + (package.archive.map { " (\(size($0.size)))" } ?? "")
        }
        Output.line("  Packages            " + (packages.isEmpty ? style.dim("all installed") : packages.joined(separator: "\n                      ")))
        Output.line("  Emulator            " + (plan.createEmulator ? "create one" : style.dim("skipped")))
        if let change = plan.shellChange {
            Output.line("  Shell profile       " + (change.replacesExisting ? "update" : "add") + " block in \(options.shell.profilePath)")
        }
        Output.line("  Download            \(size(plan.downloadSize))")
        if !plan.unacceptedLicenses.isEmpty {
            Output.line("  Licenses to accept  \(plan.unacceptedLicenses.map(\.id).joined(separator: ", "))")
        }
        Output.line()
    }

    func dryRunDone(_ plan: SetupPlan) {
        if json {
            emit(["event": "done", "ok": true, "dryRun": true])
        } else {
            Output.line(Style.current.dim("Dry run: nothing was changed."))
        }
    }

    func handle(_ event: SetupEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case let .started(step):
            if json { emit(["event": "started", "step": step.rawValue]) } else { Output.errorLine("→ \(step.title)") }
        case let .progress(step, received, total):
            let percent = total > 0 ? Int(received * 100 / total) : 0
            guard lastPercent[step] != percent else { return }
            lastPercent[step] = percent
            if json {
                emit(["event": "progress", "step": step.rawValue, "received": received, "total": total, "percent": percent])
            } else if interactive {
                FileHandle.standardError.write(Data("\r\u{1B}[2K  \(percent)% of \(size(total))".utf8))
            }
        case let .detail(step, text):
            if json {
                emit(["event": "detail", "step": step.rawValue, "message": text])
            } else if interactive {
                FileHandle.standardError.write(Data("\r\u{1B}[2K  \(text)".utf8))
            }
        case let .finished(step, summary):
            if json {
                emit(["event": "finished", "step": step.rawValue, "summary": summary])
            } else {
                if interactive { FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8)) }
                Output.errorLine("  ✓ \(summary)")
            }
        case let .skipped(step, reason):
            if json { emit(["event": "skipped", "step": step.rawValue, "reason": reason]) } else { Output.errorLine("  – \(reason)") }
        }
    }

    func done(_ result: SetupResult, options: SetupOptions) {
        let exports = ShellExports.lines(sdkPath: options.sdkRoot.path, java: result.java, shell: options.shell)
        if json {
            emit([
                "event": "done",
                "ok": result.report.status != .error,
                "status": result.report.status.rawValue,
                "javaHome": result.java?.home as Any,
                "emulator": result.emulator?.name as Any,
                "shellBackup": result.shellBackup?.path as Any,
                "exports": exports,
            ])
            return
        }
        let style = Style.current
        Output.line()
        Output.line(result.report.status == .error ? style.yellow("Setup finished with problems. Run `andyman doctor` for details.") : style.green("Android development is ready."))
        if let emulator = result.emulator {
            Output.line("Start your emulator with: andyman emulator start \(emulator.name)")
        }
        if result.shellBackup != nil || options.writeShellProfile {
            Output.line("Open a new terminal window to pick up the environment changes.")
        } else if !ShellProfileEditor.isConfigured(environment: LoginEnvironment.overlay(ProcessInfo.processInfo.environment).environment, sdkPath: options.sdkRoot.path) {
            Output.line("Add these to \(options.shell.profilePath) (or rerun with --write-shell-profile):")
            exports.forEach { Output.line("  \($0)") }
        }
    }
}

struct JDKCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jdk",
        abstract: "List installed JDKs or install Eclipse Temurin.",
        subcommands: [List.self, Install.self, Use.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List installed JDKs and which one is used.")

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let context = CommandContext(options)
            let locator = JavaLocator()
            let installations = await locator.installations()
            let selected = locator.resolve(settings: SharedPreferences().javaHomeOverride, environment: context.environment, installations: installations).selected

            if options.json {
                struct Payload: Encodable {
                    var schemaVersion = Output.schemaVersion
                    var selected: String?
                    var installations: [JavaInstallation]
                }
                try Output.json(Payload(selected: selected?.home, installations: installations))
                return
            }
            guard !installations.isEmpty else {
                Output.line("No JDKs found. Install one with `andyman jdk install 17`.")
                return
            }
            Output.table(header: ["", "VERSION", "NAME", "HOME"], rows: installations.map { java in
                [java.home == selected?.home ? "*" : "", java.version ?? "?", java.name ?? java.vendor ?? "", java.home]
            })
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download and install Eclipse Temurin.")

        @OptionGroup var options: GlobalOptions
        @Argument(help: "Major version: 17, 21 or 25.") var major = JDKInstaller.recommendedMajor
        @Option(help: ArgumentHelp("Install into this folder instead of ~/Library/Java/JavaVirtualMachines.", valueName: "path"))
        var destination: String?

        func validate() throws {
            guard JDKInstaller.installableMajors.contains(major) else { throw ValidationError("Choose one of \(JDKInstaller.installableMajors.map(String.init).joined(separator: ", ")).") }
        }

        func run() async throws {
            let installer = JDKInstaller(destination: destination.map { URL(fileURLWithPath: ShellEnvironment.expandTilde($0), isDirectory: true) } ?? JDKInstaller.defaultDestination)
            let java: JavaInstallation
            do {
                let release = try await installer.latestRelease(major: major)
                if !options.json { Output.errorLine("Downloading Eclipse Temurin \(release.version) (\(ByteCountFormatter.string(fromByteCount: release.size, countStyle: .file)))…") }
                let interactive = isatty(STDERR_FILENO) == 1 && !options.json
                java = try await installer.install(release) { received, total in
                    if interactive, total > 0 {
                        FileHandle.standardError.write(Data("\r\u{1B}[2K  \(received * 100 / total)%".utf8))
                    }
                }
                if interactive { FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8)) }
            } catch {
                throw CLIError(code: "jdk_install_failed", message: error.localizedDescription)
            }
            try Output.result(json: options.json, message: "Installed \(java.displayName) at \(java.home).", fields: ["javaHome": java.home, "version": java.version ?? ""])
        }
    }

    struct Use: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Make a JDK the default for terminals (sets JAVA_HOME in your shell profile).",
            discussion: """
            Writes JAVA_HOME (plus ANDROID_HOME and PATH) into the fenced Andyman block of \
            your shell profile, backing the file up first. Takes effect in new terminals. \
            Use --dry-run to see the block without writing it.
            """
        )

        @OptionGroup var options: GlobalOptions
        @Argument(help: "A major version (17) or a JDK home path.") var jdk: String
        @Option(help: "Shell whose profile to edit: zsh, bash or fish (default: $SHELL).") var shell: ShellExports.Shell?
        @Flag(help: "Show the change without writing it.") var dryRun = false

        func run() async throws {
            let context = CommandContext(options)
            let installations = await JavaLocator().installations()
            let java: JavaInstallation?
            if let major = Int(jdk) {
                java = installations.first { $0.majorVersion == major }
            } else {
                java = JavaLocator.installation(at: ShellEnvironment.expandTilde(jdk), source: .knownLocation)
            }
            guard let java else {
                throw CLIError(code: "jdk_not_found", message: "No JDK \(jdk) is installed.", hint: Int(jdk) != nil ? "Install it with `andyman jdk install \(jdk)`." : nil, exitStatus: .notFound)
            }
            let shell = shell ?? ShellExports.Shell(shellPath: context.environment["SHELL"])
            let lines = ShellExports.lines(sdkPath: context.sdk?.path, java: java, shell: shell)
            let editor = ShellProfileEditor(shell: shell)
            let change = editor.proposedChange(lines: lines)
            let others = editor.otherAssignments(of: "JAVA_HOME")
            let othersNote = others.map { other in
                "Note: \(shell.profilePath) line \(other.line) also sets JAVA_HOME (\(other.text)). " +
                    (other.overridesBlock ? "It comes after the Andyman block, so it wins: remove it for this change to take effect." : "The Andyman block comes after it, so the block wins.")
            }
            if dryRun || !change.isNeeded {
                let message = change.isNeeded
                    ? "Dry run: would \(change.replacesExisting ? "update the Andyman block in" : "add this block to") \(shell.profilePath):\n" + change.block.joined(separator: "\n")
                    : "\(shell.profilePath) already uses \(java.displayName)."
                try Output.result(
                    json: options.json,
                    message: ([message] + othersNote).joined(separator: "\n"),
                    fields: [
                        "profile": shell.profilePath, "block": change.block, "dryRun": dryRun,
                        "wouldChange": change.isNeeded, "changed": false, "otherAssignments": others,
                    ]
                )
                return
            }
            let backup: URL?
            do {
                backup = try editor.apply(lines: lines)
            } catch {
                throw CLIError(code: "profile_write_failed", message: "Couldn't update \(shell.profilePath): \(error.localizedDescription)")
            }
            try Output.result(
                json: options.json,
                message: (["New terminals use \(java.displayName). Updated \(shell.profilePath)" + (backup.map { " (backup: \($0.lastPathComponent))" } ?? "") + "."] + othersNote).joined(separator: "\n"),
                fields: ["profile": shell.profilePath, "block": change.block, "changed": true, "backup": backup?.path ?? "", "javaHome": java.home, "otherAssignments": others]
            )
        }
    }
}

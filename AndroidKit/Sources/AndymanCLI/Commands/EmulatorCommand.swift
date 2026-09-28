import AndroidKit
import ArgumentParser
import Foundation

struct EmulatorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "emulator",
        abstract: "Start, stop and list running emulators, and act on running ones.",
        subcommands: [List.self, Start.self, Stop.self, Reverse.self, DevMenu.self, Reload.self, Screenshot.self, Install.self]
    )
}

extension EmulatorCommand {
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List running emulators.")

        @OptionGroup var options: GlobalOptions

        struct Instance: Encodable {
            let emulator: RunningEmulator
            let booted: Bool

            private enum CodingKeys: String, CodingKey { case serial, booted }

            func encode(to encoder: any Encoder) throws {
                try emulator.encode(to: encoder)
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(emulator.serial, forKey: .serial)
                try container.encode(booted, forKey: .booted)
            }
        }

        func run() async throws {
            let context = CommandContext(options)
            let running = RunningEmulators.scan()
            var instances: [Instance] = []
            if let controller = try? context.controller() {
                for emulator in running {
                    instances.append(Instance(emulator: emulator, booted: await controller.isBooted(emulator)))
                }
            } else {
                instances = running.map { Instance(emulator: $0, booted: false) }
            }

            if options.json {
                struct Payload: Encodable {
                    var schemaVersion = Output.schemaVersion
                    var emulators: [Instance]
                }
                try Output.json(Payload(emulators: instances))
                return
            }
            guard !instances.isEmpty else {
                Output.line("No emulators running.")
                return
            }
            Output.table(
                header: ["SERIAL", "AVD", "PID", "STATE"],
                rows: instances.map { [$0.emulator.serial, $0.emulator.avdName, "\($0.emulator.pid)", $0.booted ? "booted" : "booting"] }
            )
        }
    }

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start an emulator.",
            discussion: """
            Returns once the emulator is running and has an adb serial. With --wait-boot, waits \
            until Android has finished booting. If the AVD is already running, reports that \
            instance instead of failing. The emulator keeps running after this command exits.
            """
        )

        @OptionGroup var options: GlobalOptions
        @Argument(help: "AVD name, as shown by `andyman avd list`.") var name: String
        @Flag(help: "Boot from scratch, ignoring the quick-boot snapshot.") var cold = false
        @Flag(help: "Factory-reset user data before booting.") var wipe = false
        @Flag(help: "Don't save a quick-boot snapshot on exit.") var noSnapshotSave = false
        @Flag(help: "Run without a window.") var headless = false
        @Option(help: "GPU mode: auto, host or swiftshader_indirect.") var gpu: EmulatorLaunchOptions.GPUMode?
        @Flag(help: "Wait until Android has finished booting.") var waitBoot = false
        @Option(help: "Seconds to wait before giving up.") var timeout: Int = 180

        struct Payload: Encodable {
            var schemaVersion = Output.schemaVersion
            var avd: String
            var serial: String
            var pid: Int32
            var booted: Bool
            var alreadyRunning: Bool
            var logPath: String
        }

        func run() async throws {
            let context = CommandContext(options)
            let controller = try context.controller()
            let device = try context.device(named: name)
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(timeout)

            do {
                var alreadyRunning = false
                let emulator: RunningEmulator
                if let existing = RunningEmulators.instance(of: device, in: RunningEmulators.scan()) {
                    emulator = existing
                    alreadyRunning = true
                } else {
                    let launchOptions = EmulatorLaunchOptions(
                        coldBoot: cold, wipeData: wipe, saveSnapshot: !noSnapshotSave, headless: headless, gpu: gpu
                    )
                    let pid = try controller.start(device, options: launchOptions, environment: context.environment)
                    if !options.json { Output.errorLine("Starting \(device.displayName)…") }
                    emulator = try await controller.waitUntilRunning(device, launcherPID: pid, timeout: deadline - clock.now)
                }

                var booted = await controller.isBooted(emulator)
                if waitBoot && !booted {
                    if !options.json { Output.errorLine("Waiting for Android to boot…") }
                    try await controller.waitForBoot(emulator, timeout: deadline - clock.now)
                    booted = true
                }

                let payload = Payload(
                    avd: device.name, serial: emulator.serial, pid: emulator.pid, booted: booted,
                    alreadyRunning: alreadyRunning, logPath: EmulatorController.logFile(for: device.name).path
                )
                if options.json {
                    try Output.json(payload)
                } else {
                    let state = booted ? "booted" : "booting"
                    let prefix = alreadyRunning ? "Already running" : "Running"
                    Output.line("\(prefix): \(device.displayName) as \(emulator.serial) (\(state)).")
                }
            } catch {
                throw CLIError(error)
            }
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop running emulators.")

        @OptionGroup var options: GlobalOptions
        @Argument(help: "AVD names or serials (emulator-5554).") var targets: [String] = []
        @Flag(help: "Stop every running emulator.") var all = false
        @Flag(help: "Kill immediately instead of shutting down cleanly.") var force = false

        func validate() throws {
            if targets.isEmpty && !all { throw ValidationError("Name an emulator to stop, or pass --all.") }
        }

        func run() async throws {
            let controller = try CommandContext(options).controller()
            let running = RunningEmulators.scan()
            let selected: [RunningEmulator]
            if all {
                selected = running
            } else {
                selected = try targets.map { target in
                    guard let match = running.first(where: { $0.avdName == target || $0.serial == target }) else {
                        throw CLIError(code: "not_running", message: "\(target) isn't running.", exitStatus: .notFound)
                    }
                    return match
                }
            }

            for emulator in selected {
                try await controller.stop(emulator, force: force)
            }
            try Output.result(
                json: options.json,
                message: selected.isEmpty ? "No emulators running." : "Stopped \(selected.map(\.avdName).joined(separator: ", ")).",
                fields: ["stopped": selected.map(\.avdName)]
            )
        }
    }
}

extension EmulatorLaunchOptions.GPUMode: ExpressibleByArgument {}

// MARK: - Quick actions on running emulators

extension EmulatorCommand {
    /// Finds a running emulator by AVD name or serial and prepares actions on it.
    static func actions(for target: String, options: GlobalOptions) throws -> (EmulatorActions, RunningEmulator) {
        let sdk = try CommandContext(options).requireSDK()
        guard let emulator = RunningEmulators.scan().first(where: { $0.avdName == target || $0.serial == target }) else {
            throw CLIError(code: "not_running", message: "\(target) isn't running.", hint: "Start it with `andyman emulator start \(target) --wait-boot`.", exitStatus: .notFound)
        }
        return (EmulatorActions(sdkRoot: sdk.url, serial: emulator.serial), emulator)
    }

    static func perform(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let error as EmulatorActionError {
            switch error {
            case .adbMissing: throw CLIError(code: "adb_not_installed", message: error.localizedDescription, exitStatus: .missingPrerequisite)
            case .failed: throw CLIError(code: "action_failed", message: error.localizedDescription)
            }
        }
    }

    struct Reverse: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Forward a port from the emulator to this Mac (adb reverse), e.g. for Metro."
        )

        @OptionGroup var options: GlobalOptions
        @Argument(help: "AVD name or serial.") var target: String
        @Option(help: "Port to forward.") var port = 8081

        func run() async throws {
            let (actions, emulator) = try EmulatorCommand.actions(for: target, options: options)
            try await EmulatorCommand.perform { try await actions.reverse(port: port) }
            try Output.result(json: options.json, message: "\(emulator.avdName) reaches this Mac's port \(port) as localhost:\(port).", fields: ["serial": emulator.serial, "port": port])
        }
    }

    struct DevMenu: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "dev-menu", abstract: "Open React Native's developer menu.")

        @OptionGroup var options: GlobalOptions
        @Argument(help: "AVD name or serial.") var target: String

        func run() async throws {
            let (actions, emulator) = try EmulatorCommand.actions(for: target, options: options)
            try await EmulatorCommand.perform { try await actions.openDevMenu() }
            try Output.result(json: options.json, message: "Opened the developer menu on \(emulator.avdName).", fields: ["serial": emulator.serial])
        }
    }

    struct Reload: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Reload the React Native app in front (like pressing R twice).")

        @OptionGroup var options: GlobalOptions
        @Argument(help: "AVD name or serial.") var target: String

        func run() async throws {
            let (actions, emulator) = try EmulatorCommand.actions(for: target, options: options)
            try await EmulatorCommand.perform { try await actions.reloadApp() }
            try Output.result(json: options.json, message: "Reloaded the app on \(emulator.avdName).", fields: ["serial": emulator.serial])
        }
    }

    struct Screenshot: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Save a PNG screenshot (to where macOS saves screenshots, unless --output is given).")

        @OptionGroup var options: GlobalOptions
        @Argument(help: "AVD name or serial.") var target: String
        @Option(help: ArgumentHelp("File to write.", valueName: "path")) var output: String?

        func run() async throws {
            let (actions, emulator) = try EmulatorCommand.actions(for: target, options: options)
            let name = (try? CommandContext(options).device(named: emulator.avdName).displayName) ?? emulator.avdName
            let destination = output.map { URL(fileURLWithPath: ShellEnvironment.expandTilde($0)) }
                ?? EmulatorActions.defaultScreenshotURL(deviceName: name)
            try await EmulatorCommand.perform { try await actions.screenshot(to: destination) }
            try Output.result(json: options.json, message: "Saved \(destination.path).", fields: ["serial": emulator.serial, "path": destination.path])
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Install or update an APK on a running emulator.")

        @OptionGroup var options: GlobalOptions
        @Argument(help: "AVD name or serial.") var target: String
        @Argument(help: "The .apk file.") var apk: String

        func run() async throws {
            let file = URL(fileURLWithPath: ShellEnvironment.expandTilde(apk))
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw CLIError(code: "not_found", message: "\(file.path) doesn't exist.", exitStatus: .notFound)
            }
            let (actions, emulator) = try EmulatorCommand.actions(for: target, options: options)
            try await EmulatorCommand.perform { try await actions.install(apk: file) }
            try Output.result(json: options.json, message: "Installed \(file.lastPathComponent) on \(emulator.avdName).", fields: ["serial": emulator.serial, "apk": file.path])
        }
    }
}

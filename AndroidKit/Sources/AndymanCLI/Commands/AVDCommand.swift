import AndroidKit
import ArgumentParser
import Foundation

struct AVDCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "avd",
        abstract: "List and manage Android Virtual Devices.",
        subcommands: [List.self, Info.self, Create.self, Edit.self, Rename.self, Duplicate.self, Snapshot.self, Wipe.self, Delete.self, Repair.self]
    )
}

/// A device plus its running instance, flattened into one JSON object.
struct DeviceEntry: Encodable {
    let device: VirtualDevice
    let running: RunningEmulator?

    private enum CodingKeys: String, CodingKey { case running }

    func encode(to encoder: any Encoder) throws {
        try device.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(running, forKey: .running)
    }
}

extension AVDCommand {
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List virtual devices and any problems with them.")

        @OptionGroup var options: GlobalOptions

        struct Payload: Encodable {
            var schemaVersion = Output.schemaVersion
            var directory: String
            var devices: [DeviceEntry]
            var issues: [AVDIssue]
        }

        func run() async throws {
            let context = CommandContext(options)
            let scan = context.catalog.scan()
            let running = RunningEmulators.scan()
            let entries = scan.devices.map { DeviceEntry(device: $0, running: RunningEmulators.instance(of: $0, in: running)) }

            if options.json {
                try Output.json(Payload(directory: scan.directory, devices: entries, issues: scan.issues))
                return
            }

            let style = Style.current
            guard !entries.isEmpty || !scan.issues.isEmpty else {
                Output.line("No virtual devices in \(scan.directory).")
                return
            }
            let rows = entries.map { entry -> [String] in
                let status: String
                if let running = entry.running {
                    status = style.green("running") + " (\(running.serial))"
                } else if let problem = entry.device.problems.first {
                    status = style.red(problem.shortDescription)
                } else {
                    status = style.dim("stopped")
                }
                return [
                    entry.device.name,
                    entry.device.androidVersion ?? "–",
                    entry.device.apiLevel ?? "–",
                    entry.device.abi ?? "–",
                    status,
                ]
            }
            Output.table(header: ["NAME", "ANDROID", "API", "ABI", "STATUS"], rows: rows)

            if !scan.issues.isEmpty {
                Output.line()
                Output.line(style.yellow("Needs attention:"))
                for issue in scan.issues {
                    Output.line("  \(issue.name): \(issue.message)")
                }
                Output.line(style.dim("  Run `andyman avd repair` to see fixes."))
            }
        }
    }

    struct Info: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show details for one virtual device.")

        @OptionGroup var options: GlobalOptions
        @Argument(help: "AVD name, as shown by `andyman avd list`.") var name: String

        func run() async throws {
            let context = CommandContext(options)
            let device = try context.device(named: name)
            let running = RunningEmulators.instance(of: device, in: RunningEmulators.scan())

            if options.json {
                struct Payload: Encodable {
                    var schemaVersion = Output.schemaVersion
                    var device: DeviceEntry
                    var diskUsageBytes: Int64
                    var logPath: String
                }
                try Output.json(Payload(
                    device: DeviceEntry(device: device, running: running),
                    diskUsageBytes: AVDCatalog.diskUsage(of: device),
                    logPath: EmulatorController.logFile(for: device.name).path
                ))
                return
            }

            var rows: [(String, String)] = [
                ("Name", device.name),
                ("Display name", device.displayName),
                ("Android", [device.androidVersion, device.apiLevel.map { "API \($0)" }].compactMap(\.self).joined(separator: ", ")),
                ("System image", device.systemImagePackage ?? "–"),
                ("Device", [device.manufacturer, device.deviceName].compactMap(\.self).joined(separator: " ")),
                ("RAM", device.ramMB.map { "\($0) MB" } ?? "–"),
                ("Storage", device.dataPartitionSize ?? "–"),
                ("Disk usage", ByteCountFormatter.string(fromByteCount: AVDCatalog.diskUsage(of: device), countStyle: .file)),
                ("Path", device.path),
                ("Status", running.map { "running (\($0.serial), pid \($0.pid))" } ?? "stopped"),
            ]
            if let width = device.screenWidth, let height = device.screenHeight {
                rows.insert(("Screen", "\(width)×\(height)" + (device.screenDensity.map { " @ \($0) dpi" } ?? "")), at: 5)
            }
            for problem in device.problems {
                rows.append(("Problem", problem.shortDescription))
            }
            let width = rows.map(\.0.count).max() ?? 0
            for (key, value) in rows {
                Output.line("\(Style.current.bold(key.padding(toLength: width, withPad: " ", startingAt: 0)))  \(value)")
            }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Move a virtual device to the Trash.")

        @OptionGroup var options: GlobalOptions
        @Argument(help: "AVD name.") var name: String
        @Flag(help: "Confirm the deletion.") var yes = false

        func run() async throws {
            guard yes else { throw CLIError.confirmationRequired("Deleting \(name)") }
            let context = CommandContext(options)
            let device = try context.device(named: name)
            do {
                try context.catalog.delete(device)
            } catch {
                throw CLIError(error)
            }
            try Output.result(json: options.json, message: "Moved \(device.displayName) to the Trash.", fields: ["deleted": device.name])
        }
    }

    struct Wipe: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Factory-reset a virtual device (user data, cache and snapshots).",
            discussion: "The next boot is a cold boot into a fresh device."
        )

        @OptionGroup var options: GlobalOptions
        @Argument(help: "AVD name.") var name: String
        @Flag(help: "Confirm the wipe.") var yes = false

        func run() async throws {
            guard yes else { throw CLIError.confirmationRequired("Wiping \(name)") }
            let context = CommandContext(options)
            let device = try context.device(named: name)
            do {
                try context.catalog.wipeData(device)
            } catch {
                throw CLIError(error)
            }
            try Output.result(json: options.json, message: "Wiped \(device.displayName).", fields: ["wiped": device.name])
        }
    }

    struct Repair: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Find and fix broken AVD entries.",
            discussion: """
            Without --yes, lists problems and the fix for each. With --yes, applies them: \
            entries whose files are missing are moved to the Trash, and folders the emulator \
            can't see get their .ini restored.
            """
        )

        @OptionGroup var options: GlobalOptions
        @Flag(help: "Apply the fixes.") var yes = false

        struct Payload: Encodable {
            var schemaVersion = Output.schemaVersion
            var issues: [AVDIssue]
            var fixed: Bool
        }

        func run() async throws {
            let catalog = CommandContext(options).catalog
            let issues = catalog.scan().issues
            if yes {
                for issue in issues {
                    do { try catalog.fix(issue) } catch { throw CLIError(error) }
                }
            }

            if options.json {
                try Output.json(Payload(issues: issues, fixed: yes))
                return
            }
            guard !issues.isEmpty else {
                Output.line("No problems found.")
                return
            }
            for issue in issues {
                let action = yes ? "fixed" : "fix"
                Output.line("\(issue.name): \(issue.message) (\(action): \(issue.fixTitle.lowercased()))")
            }
            if !yes { Output.line(Style.current.dim("Run again with --yes to apply.")) }
        }
    }
}

extension VirtualDevice.Problem {
    var shortDescription: String {
        switch self {
        case let .systemImageMissing(package): "system image missing (\(package))"
        case .configMissing: "config.ini missing"
        }
    }
}

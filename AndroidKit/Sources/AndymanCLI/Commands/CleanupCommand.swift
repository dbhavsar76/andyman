import AndroidKit
import ArgumentParser
import Foundation

struct CleanupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Free disk space: Gradle caches and old Gradle versions, emulator snapshots, Metro and SDK leftovers.",
        subcommands: [List.self, Run.self]
    )

    /// A target with its measured size, as printed and encoded.
    struct Sized: Encodable {
        var target: CleanupTarget
        var size: Int64

        private enum CodingKeys: String, CodingKey { case size }

        func encode(to encoder: any Encoder) throws {
            try target.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(size, forKey: .size)
        }
    }

    static func targets(_ context: CommandContext) -> [CleanupTarget] {
        let running = Set(RunningEmulators.scan().map(\.avdName))
        return Cleanup(sdkRoot: context.sdk?.url, environment: context.environment)
            .targets(devices: context.catalog.scan().devices, running: running)
    }

    static func measure(_ targets: [CleanupTarget]) async -> [Sized] {
        await withTaskGroup(of: (Int, Int64).self) { group in
            for (index, target) in targets.enumerated() {
                group.addTask { (index, Cleanup.size(of: target)) }
            }
            var sizes = [Int64](repeating: 0, count: targets.count)
            for await (index, size) in group { sizes[index] = size }
            return zip(targets, sizes).map { Sized(target: $0, size: $1) }
        }
    }

    static func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// Deletes `targets` (stopping Gradle daemons first when needed), or lists them with --dry-run.
    static func perform(_ targets: [CleanupTarget], options: GlobalOptions, dryRun: Bool, yes: Bool, action: String) async throws {
        let sized = await measure(targets)
        let total = sized.reduce(0) { $0 + $1.size }
        if dryRun || targets.isEmpty {
            if options.json {
                struct Payload: Encodable {
                    var schemaVersion = Output.schemaVersion
                    var dryRun: Bool
                    var targets: [Sized]
                    var total: Int64
                }
                try Output.json(Payload(dryRun: true, targets: sized, total: total))
            } else if targets.isEmpty {
                Output.line("Nothing to clean.")
            } else {
                for item in sized {
                    Output.line("\(item.target.title): \(format(item.size))")
                    for path in item.target.paths.prefix(5) { Output.line(Style.current.dim("  \(path)")) }
                    if item.target.paths.count > 5 { Output.line(Style.current.dim("  …and \(item.target.paths.count - 5) more")) }
                }
                Output.line("Would free \(format(total)). Dry run: nothing was deleted.")
            }
            return
        }
        guard yes else { throw CLIError.confirmationRequired(action) }

        var stoppedDaemons = 0
        if targets.contains(where: \.needsGradleStopped) {
            let daemons = await GradleDaemons.running()
            if !daemons.isEmpty {
                if !options.json { Output.errorLine("Stopping \(daemons.count) Gradle daemon(s)…") }
                stoppedDaemons = await GradleDaemons.stop(daemons)
            }
        }

        var freed: Int64 = 0
        var cleaned: [String] = []
        for target in targets {
            do {
                freed += try Cleanup.clean(target)
                cleaned.append(target.id)
            } catch {
                throw CLIError(code: "cleanup_failed", message: "Couldn't delete \(target.title): \(error.localizedDescription)")
            }
        }
        try Output.result(
            json: options.json,
            message: "Freed \(format(freed)).",
            fields: ["cleaned": cleaned, "freed": freed, "stoppedDaemons": stoppedDaemons]
        )
    }
}

extension CleanupCommand {
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List what can be cleaned, with sizes.")

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let sized = await CleanupCommand.measure(CleanupCommand.targets(CommandContext(options))).filter { $0.size > 0 }
            if options.json {
                struct Payload: Encodable {
                    var schemaVersion = Output.schemaVersion
                    var targets: [Sized]
                }
                try Output.json(Payload(targets: sized))
                return
            }
            guard !sized.isEmpty else {
                Output.line("Nothing to clean.")
                return
            }
            Output.table(header: ["ID", "SIZE", "WHAT"], rows: sized.map { [$0.target.id, CleanupCommand.format($0.size), $0.target.title] })
            Output.line()
            Output.line(Style.current.dim("Clean with `andyman cleanup run <id…> --yes`, or --recommended for the safe ones."))
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete cleanup targets by ID (see `andyman cleanup list`).",
            discussion: """
            Deleted files are gone for good (they're caches, re-created when needed). Gradle \
            daemons are stopped first when Gradle files are involved. Pass a kind (like \
            gradle-distribution) to select every target of that kind.
            """
        )

        @OptionGroup var options: GlobalOptions
        @Argument(help: "Target IDs or kinds.") var ids: [String] = []
        @Flag(help: "Select the targets that are always safe to delete.") var recommended = false
        @Flag(help: "Select everything.") var all = false
        @Flag(help: "Show what would be deleted.") var dryRun = false
        @Flag(help: "Confirm the deletion.") var yes = false

        func validate() throws {
            if ids.isEmpty && !recommended && !all { throw ValidationError("Name what to clean, or pass --recommended or --all.") }
        }

        func run() async throws {
            let available = CleanupCommand.targets(CommandContext(options))
            var selected: [CleanupTarget] = []
            for id in ids {
                let matches = available.filter { $0.id == id || $0.kind.rawValue == id }
                guard !matches.isEmpty else {
                    throw CLIError(code: "not_found", message: "Nothing to clean named \(id).", hint: "Run `andyman cleanup list` to see IDs.", exitStatus: .notFound)
                }
                selected += matches
            }
            if recommended { selected += available.filter(\.recommended) }
            if all { selected = available }
            var seen = Set<String>()
            selected = selected.filter { seen.insert($0.id).inserted }
            try await CleanupCommand.perform(selected, options: options, dryRun: dryRun, yes: yes, action: "Deleting \(selected.map(\.id).joined(separator: ", "))")
        }
    }
}

struct GradleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gradle",
        abstract: "See and stop Gradle and Kotlin daemons.",
        subcommands: [Status.self, Stop.self]
    )

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List running Gradle and Kotlin daemons and their memory use.")

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let daemons = await GradleDaemons.running()
            if options.json {
                struct Payload: Encodable {
                    var schemaVersion = Output.schemaVersion
                    var daemons: [GradleDaemon]
                }
                try Output.json(Payload(daemons: daemons))
                return
            }
            guard !daemons.isEmpty else {
                Output.line("No Gradle daemons running.")
                return
            }
            Output.table(header: ["PID", "KIND", "VERSION", "MEMORY"], rows: daemons.map {
                ["\($0.pid)", $0.kind.rawValue, $0.version ?? "", ByteCountFormatter.string(fromByteCount: $0.memory, countStyle: .memory)]
            })
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop every Gradle and Kotlin daemon (like `gradle --stop`, for all Gradle versions).",
            discussion: "Builds in progress fail. Daemons that don't exit within 5 seconds are force-quit."
        )

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let daemons = await GradleDaemons.running()
            let stopped = await GradleDaemons.stop(daemons)
            let freed = daemons.reduce(0) { $0 + $1.memory }
            try Output.result(
                json: options.json,
                message: stopped == 0 ? "No Gradle daemons running." : "Stopped \(stopped) daemon(s), freeing \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .memory)) of memory.",
                fields: ["stopped": stopped, "memory": freed]
            )
        }
    }
}

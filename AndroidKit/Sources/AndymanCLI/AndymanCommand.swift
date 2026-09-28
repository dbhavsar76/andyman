import AndroidKit
import ArgumentParser
import Foundation

public struct AndymanCommand: AsyncParsableCommand {
    public static let version = "0.1.0"

    public static let configuration = CommandConfiguration(
        commandName: "andyman",
        abstract: "Manage Android emulators, SDK packages and toolchains without Android Studio.",
        discussion: """
        Every command accepts --json for machine-readable output. Commands never prompt; \
        destructive operations require --yes.

        Exit codes: 0 success, 1 failure, 2 usage error, 3 not found, 4 license not accepted, \
        5 missing prerequisite (SDK, JDK, tools), 6 timeout.
        """,
        version: version,
        subcommands: [DoctorCommand.self, EnvCommand.self, AVDCommand.self, EmulatorCommand.self, DevicesCommand.self, ImagesCommand.self, SDKCommand.self, LicensesCommand.self, SetupCommand.self, JDKCommand.self, ProjectCommand.self, GradleCommand.self, CleanupCommand.self, SkillCommand.self]
    )

    public init() {}

    /// Parses and runs a command, mapping every failure to a documented exit code.
    /// Use this instead of `main()`, which would exit with ArgumentParser's own codes.
    public static func run(arguments: [String] = Array(CommandLine.arguments.dropFirst())) async -> Int32 {
        let wantsJSON = arguments.contains("--json")
        do {
            var command = try parseAsRoot(arguments)
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
            return ExitStatus.success.rawValue
        } catch let error as CLIError {
            Output.error(error, json: wantsJSON)
            return error.exitStatus.rawValue
        } catch let error as ExitCode {
            return error.rawValue
        } catch {
            // ArgumentParser's own outcomes: --help/--version (success) or a usage error.
            if exitCode(for: error) == .success {
                Output.line(fullMessage(for: error))
                return ExitStatus.success.rawValue
            }
            if wantsJSON {
                Output.error(.usage(message(for: error)), json: true)
            } else {
                Output.errorLine(fullMessage(for: error))
            }
            return ExitStatus.usage.rawValue
        }
    }
}

/// Options every command accepts.
struct GlobalOptions: ParsableArguments {
    @Flag(help: "Print machine-readable JSON.")
    var json = false

    @Option(help: ArgumentHelp("Use the Android SDK at this path.", valueName: "path"))
    var sdk: String?
}

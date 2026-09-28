import AndroidKit
import ArgumentParser
import Foundation

struct ProjectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "project",
        abstract: "Check a React Native or Flutter project's Android requirements, or clean its build.",
        subcommands: [Check.self, Clean.self]
    )
}

extension ProjectCommand {
    struct Check: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Compare what a project needs (SDK platform, build tools, NDK, CMake, JDK) with what's installed.",
            discussion: """
            Reads android/build.gradle, app/build.gradle, gradle.properties and React Native's \
            defaults without running Gradle. With --fix, installs missing SDK packages and fixes \
            local.properties; a JDK problem is only reported (see `andyman jdk`). \
            Exits with 5 when something required is missing; warnings still exit 0.
            """
        )

        @OptionGroup var options: GlobalOptions
        @Argument(help: "The project folder (or its android/ folder).") var path = "."
        @Flag(help: "Install missing packages and fix local.properties.") var fix = false
        @Flag(help: "With --fix, accept the licenses of packages being installed.") var acceptLicenses = false
        @Flag(help: "With --fix, show what would be installed and changed (with sizes and licenses) without doing it.") var dryRun = false

        func run() async throws {
            let context = CommandContext(options)
            var report = try await ProjectCommand.report(path: path, context: context)

            if fix && dryRun {
                let preview = report.missingPackages.isEmpty ? nil : try await SDKCommand.plan(report.missingPackages, options: options)
                let writes = report.checks.compactMap { check -> String? in
                    if case let .writeLocalProperties(sdkPath) = check.fix { return "android/local.properties: sdk.dir=\(sdkPath)" }
                    return nil
                }
                if options.json {
                    struct Payload: Encodable {
                        var schemaVersion = Output.schemaVersion
                        var dryRun = true
                        var report: ProjectReport
                        var install: SDKCommand.PlanPreview?
                        var fileChanges: [String]
                    }
                    try Output.json(Payload(report: report, install: preview, fileChanges: writes))
                } else {
                    printHuman(report)
                    Output.line()
                    if let preview { try preview.print(json: false) }
                    writes.forEach { Output.line("Would write \($0)") }
                    if preview == nil && writes.isEmpty { Output.line("Nothing for --fix to do.") }
                }
                return
            }

            if fix {
                var fixed: [String] = []
                for check in report.checks {
                    if case let .writeLocalProperties(sdkPath) = check.fix {
                        try report.project.writeLocalSDKDir(sdkPath)
                        fixed.append("local.properties")
                    }
                }
                let missing = report.missingPackages
                if !missing.isEmpty {
                    if !options.json { Output.errorLine("Installing \(missing.joined(separator: ", "))…") }
                    try await SDKCommand.install(missing, options: options, acceptLicenses: acceptLicenses, silent: options.json)
                    fixed.append(contentsOf: missing)
                }
                if !fixed.isEmpty {
                    report = try await ProjectCommand.report(path: path, context: context)
                }
            }

            if options.json {
                try Output.json(report)
            } else {
                printHuman(report)
            }
            if report.status == .error {
                throw ExitCode(ExitStatus.missingPrerequisite.rawValue)
            }
        }

        private func printHuman(_ report: ProjectReport) {
            let style = Style.current
            let project = report.project
            var summary = [project.reactNativeVersion.map { "React Native \($0)" }, project.isExpo ? "Expo" : nil, project.gradleVersion.map { "Gradle \($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
            if summary.isEmpty { summary = "Android project" }
            Output.line(style.bold(project.name) + "  " + style.dim(summary))
            Output.line(style.dim(project.root))
            Output.line()

            let width = (report.checks.map(\.title.count).max() ?? 0) + 2
            for check in report.checks {
                let symbol = switch check.status {
                case .ok: style.green("✓")
                case .warning: style.yellow("!")
                case .error: style.red("✗")
                }
                Output.line("\(symbol) \(style.bold(check.title.padding(toLength: width, withPad: " ", startingAt: 0)))\(check.message)")
                if let hint = check.hint, check.status != .ok {
                    Output.line("  \(String(repeating: " ", count: width))\(style.dim("→ \(hint)"))")
                }
            }
            Output.line()
            let missing = report.missingPackages
            switch report.status {
            case .ok:
                Output.line(style.green("Ready to build."))
            case .warning, .error:
                let problems = report.checks.filter { $0.status != .ok }.count
                let line = "\(problems) problem(s)."
                Output.line(report.status == .error ? style.red(line) : style.yellow(line))
                if !missing.isEmpty {
                    Output.line(style.dim("Run `andyman project check \(path) --fix` to install \(missing.joined(separator: ", "))."))
                }
            }
        }
    }

    struct Clean: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete the project's Android build folders (and native module build folders in node_modules).",
            discussion: "Stops Gradle daemons first. Needs --yes, or --dry-run to see what would be deleted."
        )

        @OptionGroup var options: GlobalOptions
        @Argument(help: "The project folder (or its android/ folder).") var path = "."
        @Flag(help: "Skip build folders of libraries in node_modules.") var projectOnly = false
        @Flag(help: "Show what would be deleted.") var dryRun = false
        @Flag(help: "Confirm the deletion.") var yes = false

        func run() async throws {
            let project = try ProjectCommand.load(path)
            var targets = Cleanup.projectTargets(project)
            if projectOnly { targets.removeAll { $0.kind == .projectLibraries } }
            try await CleanupCommand.perform(targets, options: options, dryRun: dryRun, yes: yes, action: "Cleaning \(project.name)")
        }
    }

    static func load(_ path: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> AndroidProject {
        do {
            return try AndroidProject.load(path, environment: environment)
        } catch let error as ProjectError {
            switch error {
            case .notFound: throw CLIError(code: "not_found", message: error.localizedDescription, exitStatus: .notFound)
            case .noAndroidFolder: throw CLIError(code: "not_an_android_project", message: error.localizedDescription, hint: "Pass the React Native project folder (the one with android/ in it).", exitStatus: .notFound)
            }
        }
    }

    static func report(path: String, context: CommandContext) async throws -> ProjectReport {
        let project = try load(path, environment: context.environment)
        let installed = context.sdk.map { LocalPackages.scan(sdkRoot: $0.url) } ?? []
        // The catalog only refines package IDs and sizes, so work offline if it can't load.
        let catalog = try? await context.catalog()
        let locator = JavaLocator()
        return ProjectDoctor().check(.init(
            project: project,
            sdk: context.sdk,
            installed: installed,
            catalog: catalog,
            javaInstallations: await locator.installations(),
            environment: context.environment,
            devices: context.catalog.scan().devices,
            defaultJava: await locator.systemDefault(),
            fromProfile: context.fromProfile
        ))
    }
}

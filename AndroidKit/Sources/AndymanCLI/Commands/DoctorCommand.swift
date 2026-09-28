import AndroidKit
import ArgumentParser
import Foundation

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check the Android SDK, JDK and shell environment.",
        discussion: "Exits with 5 when something required is missing; warnings still exit 0."
    )

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        let context = CommandContext(options)
        let report = await Doctor().run(.init(
            sdkFlag: options.sdk,
            environment: context.environment,
            fromProfile: context.fromProfile
        ))

        if options.json {
            try Output.json(report)
        } else {
            printHuman(report)
        }

        if report.status == .error {
            throw ExitCode(ExitStatus.missingPrerequisite.rawValue)
        }
    }

    private func printHuman(_ report: DoctorReport) {
        let style = Style.current
        let width = (report.checks.map(\.title.count).max() ?? 0) + 2
        for check in report.checks {
            let symbol = switch check.status {
            case .ok: style.green("✓")
            case .warning: style.yellow("!")
            case .error: style.red("✗")
            }
            let title = check.title.padding(toLength: width, withPad: " ", startingAt: 0)
            Output.line("\(symbol) \(style.bold(title))\(check.message)")
            if let hint = check.hint {
                Output.line("  \(String(repeating: " ", count: width))\(style.dim("→ \(hint)"))")
            }
        }

        let problems = report.checks.filter { $0.status != .ok }
        Output.line()
        switch report.status {
        case .ok: Output.line(style.green("Everything looks good."))
        case .warning: Output.line(style.yellow("\(problems.count) warning(s)."))
        case .error: Output.line(style.red("\(problems.count) problem(s) need attention."))
        }
    }
}

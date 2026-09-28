import AndroidKit
import AppKit
import Observation

/// The command-line tool on PATH, and the agent skill in coding agents' skill folders.
@Observable
final class AgentsStore {
    struct Entry: Identifiable, Equatable {
        var target: AgentTarget
        var state: SkillInstallState
        var id: String { target.id }
    }

    /// The bundled `andyman`.
    let bundledCLI = Bundle.main.bundleURL.appending(path: "Contents/Helpers/\(CommandLineInstall.commandName)")

    private(set) var cliStatus: CommandLineInstall.Status = .notInstalled
    private(set) var cliOnPath = false
    /// SKILL.md as this version of andyman generates it.
    private(set) var skill: String?
    private(set) var skillVersion: String?
    private(set) var agentsSnippet: String?
    private(set) var entries: [Entry] = []
    private(set) var loadError: String?
    var notice: String?
    var failure: String?

    private let runner = ProcessRunner()

    /// Agents shown: the ones found on this Mac, plus the shared folder.
    var visibleEntries: [Entry] { entries.filter { $0.target.isDetected || $0.target.id == "agents" } }
    /// Installs older than this app's skill.
    var outdated: [Entry] { entries.filter { $0.state == .outdated } }
    var installedCount: Int { entries.filter { $0.state == .current || $0.state == .outdated }.count }

    func refresh(environment: [String: String]) async {
        cliStatus = CommandLineInstall.status(bundled: bundledCLI)
        cliOnPath = CommandLineInstall.isOnPath(environment: environment)
        if skill == nil {
            do {
                let printed = try await runner.run(bundledCLI, arguments: ["skill", "print"], timeout: .seconds(20))
                let snippet = try await runner.run(bundledCLI, arguments: ["skill", "agents-md"], timeout: .seconds(20))
                guard printed.succeeded else { throw AgentsError.cli(printed.stderrString) }
                skill = printed.stdoutString
                agentsSnippet = snippet.succeeded ? snippet.stdoutString : nil
                skillVersion = skill.flatMap(AgentSkills.frontmatterVersion)
                loadError = nil
            } catch {
                loadError = "Couldn't generate the skill: \(error.localizedDescription)"
            }
        }
        updateStates()
    }

    private func updateStates() {
        let content = skill ?? ""
        entries = AgentSkills.targets().map { target in
            Entry(target: target, state: AgentSkills.state(of: AgentSkills.userSkillsFolder(target), current: content))
        }
    }

    // MARK: - Skill

    func install(_ target: AgentTarget) {
        perform {
            guard let skill else { return }
            try AgentSkills.install(skill, into: AgentSkills.userSkillsFolder(target))
            notice = "Installed for \(target.name). It's used from the agent's next session."
        }
    }

    func uninstall(_ target: AgentTarget) {
        perform {
            try AgentSkills.uninstall(from: AgentSkills.userSkillsFolder(target))
            notice = "Removed from \(target.name)."
        }
    }

    /// Updates every outdated install.
    func updateAll() {
        perform {
            guard let skill else { return }
            for entry in outdated {
                try AgentSkills.install(skill, into: AgentSkills.userSkillsFolder(entry.target))
            }
            notice = "Updated the skill."
        }
    }

    /// Installs into a project for Claude Code (`.claude/skills`) and other agents (`.agents/skills`).
    func install(inProject project: URL) {
        perform {
            guard let skill else { return }
            let targets = AgentSkills.targets().filter { ["claude", "agents"].contains($0.id) }
            for target in targets {
                try AgentSkills.install(skill, into: AgentSkills.projectSkillsFolder(target, project: project))
            }
            notice = "Installed in \(project.lastPathComponent) (.claude/skills and .agents/skills). Commit them to share it with your team."
        }
    }

    func showInFinder(_ target: AgentTarget) {
        let file = AgentSkills.skillFile(in: AgentSkills.userSkillsFolder(target))
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    func copySkill() {
        guard let skill else { return }
        copy(skill)
        notice = "Copied SKILL.md."
    }

    func copyAgentsSnippet() {
        guard let agentsSnippet else { return }
        copy(agentsSnippet)
        notice = "Copied. Paste it into AGENTS.md or CLAUDE.md."
    }

    func save(to folder: URL) {
        perform {
            guard let skill else { return }
            let file = try AgentSkills.install(skill, into: folder)
            notice = "Saved \(abbreviatedPath(file.path))."
        }
    }

    // MARK: - Command-line tool

    func installCLI(environment: [String: String]) {
        perform {
            try CommandLineInstall.install(bundled: bundledCLI)
            cliStatus = CommandLineInstall.status(bundled: bundledCLI)
            cliOnPath = CommandLineInstall.isOnPath(environment: environment)
            notice = "andyman is in ~/.local/bin."
        }
    }

    func uninstallCLI() {
        perform {
            try CommandLineInstall.uninstall()
            cliStatus = CommandLineInstall.status(bundled: bundledCLI)
            notice = "Removed andyman from ~/.local/bin."
        }
    }

    private func perform(_ body: () throws -> Void) {
        failure = nil
        notice = nil
        do {
            try body()
        } catch {
            failure = error.localizedDescription
        }
        updateStates()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum AgentsError: LocalizedError {
    case cli(String)

    var errorDescription: String? {
        switch self {
        case let .cli(message): message.isEmpty ? "andyman failed." : message
        }
    }
}

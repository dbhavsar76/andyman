import CryptoKit
import Foundation

/// A coding agent that reads Agent Skills (`<skills folder>/<name>/SKILL.md`).
public struct AgentTarget: Sendable, Equatable, Codable, Identifiable {
    /// Stable ID for the CLI: `claude`, `codex`, `agents`, …
    public var id: String
    public var name: String
    /// The agent's own folder; the agent counts as installed when it exists.
    public var home: String
    /// Where user-level skills go.
    public var userSkills: String
    /// Where project-level skills go, relative to the project root.
    public var projectSkills: String
    public var isDetected: Bool
}

public enum SkillInstallState: String, Sendable, Codable {
    case notInstalled = "not_installed"
    case current
    /// Installed by an older version; `andyman skill install` updates it.
    case outdated
    /// A skill with our name that we didn't generate; left alone.
    case foreign
}

/// Installs the generated skill into agents' skill folders and tracks its version.
///
/// The skill's frontmatter carries `metadata.generator: andyman` and a version (the CLI version
/// plus a hash of the content), so an install can tell ours from someone else's and notice
/// when it's older than what this version of the app generates.
public enum AgentSkills {
    public static let skillName = "andyman"
    public static let generator = "andyman"

    /// Agents we know the skill folders of. `agents` is the shared `~/.agents/skills` folder
    /// that several agents (and the `skills` installer) read.
    public static func targets(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AgentTarget] {
        let known: [(id: String, name: String, home: String, user: String, project: String)] = [
            ("claude", "Claude Code", ".claude", ".claude/skills", ".claude/skills"),
            ("codex", "Codex", ".codex", ".codex/skills", ".agents/skills"),
            ("agents", "Shared Skills Folder", ".agents", ".agents/skills", ".agents/skills"),
            ("gemini", "Gemini CLI", ".gemini", ".gemini/skills", ".gemini/skills"),
            ("cursor", "Cursor", ".cursor", ".cursor/skills", ".cursor/skills"),
            ("copilot", "GitHub Copilot", ".copilot", ".copilot/skills", ".github/skills"),
            ("opencode", "OpenCode", ".config/opencode", ".config/opencode/skills", ".opencode/skills"),
        ]
        return known.map { agent in
            let agentHome = home.appending(path: agent.home, directoryHint: .isDirectory)
            return AgentTarget(
                id: agent.id,
                name: agent.name,
                home: agentHome.path,
                userSkills: home.appending(path: agent.user, directoryHint: .isDirectory).path,
                projectSkills: agent.project,
                isDetected: FileManager.default.fileExists(atPath: agentHome.path)
            )
        }
    }

    /// The skill file inside a skills folder.
    public static func skillFile(in skillsFolder: URL) -> URL {
        skillsFolder.appending(path: "\(skillName)/SKILL.md")
    }

    public static func projectSkillsFolder(_ target: AgentTarget, project: URL) -> URL {
        project.appending(path: target.projectSkills, directoryHint: .isDirectory)
    }

    public static func userSkillsFolder(_ target: AgentTarget) -> URL {
        URL(fileURLWithPath: target.userSkills, isDirectory: true)
    }

    public static func state(of skillsFolder: URL, current content: String) -> SkillInstallState {
        guard let installed = try? String(contentsOf: skillFile(in: skillsFolder), encoding: .utf8) else { return .notInstalled }
        let metadata = frontmatter(installed)
        guard metadata["generator"] == generator else { return .foreign }
        return metadata["version"] == frontmatter(content)["version"] ? .current : .outdated
    }

    /// Writes the skill, replacing an older one of ours. Refuses to overwrite a skill with the
    /// same name that we didn't generate. A symlinked skill folder (the `skills` installer's
    /// layout) is written through, updating the shared copy.
    @discardableResult
    public static func install(_ content: String, into skillsFolder: URL) throws -> URL {
        if state(of: skillsFolder, current: content) == .foreign {
            throw AgentSkillError.foreignSkill(skillFile(in: skillsFolder).path)
        }
        let file = skillFile(in: skillsFolder)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Removes our skill folder (or the symlink to it). Leaves skills we didn't generate.
    public static func uninstall(from skillsFolder: URL) throws {
        let folder = skillsFolder.appending(path: skillName, directoryHint: .isDirectory)
        switch state(of: skillsFolder, current: "") {
        case .notInstalled: return
        case .foreign: throw AgentSkillError.foreignSkill(skillFile(in: skillsFolder).path)
        case .current, .outdated: try FileManager.default.removeItem(at: folder)
        }
    }

    /// `version` for a skill body: the CLI version plus a short hash, so any content change
    /// (not just a version bump) makes installed copies outdated.
    public static func version(cliVersion: String, body: String) -> String {
        let digest = SHA256.hash(data: Data(body.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(cliVersion)+\(digest)"
    }

    /// The `metadata.version` of a SKILL.md.
    public static func frontmatterVersion(_ content: String) -> String? { frontmatter(content)["version"] }

    /// The flat `key: value` pairs of a SKILL.md frontmatter, including nested `metadata:` keys.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---" else { return [:] }
        var values: [String: String] = [:]
        for line in lines.dropFirst() {
            if line == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { values[key] = value }
        }
        return values
    }
}

public enum AgentSkillError: Error, Sendable, Equatable, LocalizedError {
    case foreignSkill(String)
    case unknownAgent(String)

    public var errorDescription: String? {
        switch self {
        case let .foreignSkill(path): "\(path) is a different skill with the same name, so it was left alone."
        case let .unknownAgent(id): "There's no agent called \(id)."
        }
    }
}

/// Puts the bundled `andyman` on the user's PATH with a symlink (no admin rights needed).
public enum CommandLineInstall {
    public static let commandName = "andyman"

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin", directoryHint: .isDirectory)
    }

    /// Whether a link to `andyman` is in the default folder (so shell profiles should add it to PATH).
    public static var isLinked: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: defaultDirectory.appending(path: commandName).path)) != nil
    }

    public enum Status: Sendable, Equatable {
        case notInstalled
        /// A symlink to this app's copy.
        case installed
        /// A symlink to another copy (an older app build, say).
        case otherCopy(String)
        /// A regular file we didn't create.
        case conflict
    }

    public static func status(bundled: URL, directory: URL = defaultDirectory) -> Status {
        let link = directory.appending(path: commandName)
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
            return FileManager.default.fileExists(atPath: link.path) ? .conflict : .notInstalled
        }
        let resolved = URL(fileURLWithPath: destination, relativeTo: directory).standardizedFileURL.path
        return resolved == bundled.standardizedFileURL.path ? .installed : .otherCopy(resolved)
    }

    /// Creates (or repoints) the symlink.
    @discardableResult
    public static func install(bundled: URL, directory: URL = defaultDirectory) throws -> URL {
        let link = directory.appending(path: commandName)
        if status(bundled: bundled, directory: directory) == .conflict { throw CommandLineInstallError.conflict(link.path) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil {
            try FileManager.default.removeItem(at: link)
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundled)
        return link
    }

    /// Removes the symlink (never a regular file).
    public static func uninstall(directory: URL = defaultDirectory) throws {
        let link = directory.appending(path: commandName)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil else { return }
        try FileManager.default.removeItem(at: link)
    }

    /// Whether `directory` is on the PATH of this (login shell) environment.
    public static func isOnPath(_ directory: URL = defaultDirectory, environment: [String: String]) -> Bool {
        ShellEnvironment.pathEntries(environment).contains { SDKLocator.Candidate.samePath($0, directory.path) }
    }
}

public enum CommandLineInstallError: Error, Sendable, Equatable, LocalizedError {
    case conflict(String)

    public var errorDescription: String? {
        switch self {
        case let .conflict(path): "\(path) already exists and isn't a link to Andyman's command-line tool, so it was left alone."
        }
    }
}

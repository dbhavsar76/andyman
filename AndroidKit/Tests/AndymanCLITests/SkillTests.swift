import AndroidKit
import Foundation
import Testing
@testable import AndymanCLI

@Suite struct SkillDocumentTests {
    @Test func hasValidFrontmatter() throws {
        let skill = SkillDocument.render(executable: "/Applications/Andyman.app/Contents/Helpers/andyman")
        let lines = skill.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "---")
        #expect(lines[1] == "name: andyman")
        // The description has colons, so it must be quoted to be valid YAML.
        #expect(lines[2].hasPrefix("description: \"") && lines[2].hasSuffix("\""))
        #expect(AgentSkills.frontmatterVersion(skill)?.hasPrefix(AndymanCommand.version + "+") == true)
        #expect(skill.contains("\"/Applications/Andyman.app/Contents/Helpers/andyman\""))
    }

    @Test func referenceListsEveryCommand() {
        let reference = SkillDocument.commandReference()
        for command in ["andyman doctor", "andyman emulator start", "andyman emulator dev-menu", "andyman project check", "andyman cleanup run", "andyman devices"] {
            #expect(reference.contains("`\(command)`"), "missing \(command)")
        }
        #expect(!reference.contains("andyman skill"))
    }

    @Test func versionTracksContent() {
        let here = SkillDocument.render(executable: "andyman")
        let there = SkillDocument.render(executable: "/other/andyman")
        #expect(AgentSkills.frontmatterVersion(here) != AgentSkills.frontmatterVersion(there))
    }

    @Test func parsesSkillInstallOptions() throws {
        let install = try #require(try AndymanCommand.parseAsRoot(["skill", "install", "--agent", "claude", "--agent", "codex", "--project", "/tmp/app"]) as? SkillCommand.Install)
        #expect(install.agentOptions.agents == ["claude", "codex"])
        #expect(try install.agentOptions.selected().map(\.id) == ["claude", "codex"])
        #expect(install.agentOptions.folder(for: try install.agentOptions.selected()[0]).path == "/tmp/app/.claude/skills")
    }
}

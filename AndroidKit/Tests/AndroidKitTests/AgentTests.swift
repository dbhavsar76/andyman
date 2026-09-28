import Foundation
import Testing
@testable import AndroidKit

@Suite struct AgentSkillsTests {
    func temp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    func skill(version: String, generator: String = "andyman") -> String {
        """
        ---
        name: andyman
        description: "Test: with a colon"
        metadata:
          generator: \(generator)
          version: "\(version)"
        ---

        # Body
        """
    }

    @Test func installsUpdatesAndRemoves() throws {
        let folder = temp("skills")
        #expect(AgentSkills.state(of: folder, current: skill(version: "1")) == .notInstalled)

        let file = try AgentSkills.install(skill(version: "1"), into: folder)
        #expect(file.path.hasSuffix("andyman/SKILL.md"))
        #expect(AgentSkills.state(of: folder, current: skill(version: "1")) == .current)
        #expect(AgentSkills.state(of: folder, current: skill(version: "2")) == .outdated)

        try AgentSkills.install(skill(version: "2"), into: folder)
        #expect(AgentSkills.state(of: folder, current: skill(version: "2")) == .current)

        try AgentSkills.uninstall(from: folder)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "andyman").path))
    }

    @Test func leavesOtherSkillsAlone() throws {
        let folder = temp("skills")
        let file = AgentSkills.skillFile(in: folder)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try skill(version: "9", generator: "someone-else").write(to: file, atomically: true, encoding: .utf8)
        #expect(AgentSkills.state(of: folder, current: skill(version: "1")) == .foreign)
        #expect(throws: AgentSkillError.self) { try AgentSkills.install(skill(version: "1"), into: folder) }
        #expect(throws: AgentSkillError.self) { try AgentSkills.uninstall(from: folder) }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func writesThroughSymlinkedSkillFolders() throws {
        // The `skills` installer keeps one copy in ~/.agents/skills and links agent folders to it.
        let shared = temp("shared")
        let claude = temp("claude")
        try AgentSkills.install(skill(version: "1"), into: shared)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: claude.appending(path: "andyman"), withDestinationURL: shared.appending(path: "andyman"))
        try AgentSkills.install(skill(version: "2"), into: claude)
        #expect(AgentSkills.state(of: shared, current: skill(version: "2")) == .current)
    }

    @Test func detectsAgents() throws {
        let home = temp("home")
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        let targets = AgentSkills.targets(home: home)
        #expect(targets.first { $0.id == "claude" }?.isDetected == true)
        #expect(targets.first { $0.id == "codex" }?.isDetected == false)
        #expect(targets.first { $0.id == "claude" }?.userSkills == home.appending(path: ".claude/skills").path)
    }

    @Test func versionChangesWithContent() {
        #expect(AgentSkills.version(cliVersion: "0.1.0", body: "a") != AgentSkills.version(cliVersion: "0.1.0", body: "b"))
        #expect(AgentSkills.version(cliVersion: "0.1.0", body: "a").hasPrefix("0.1.0+"))
        #expect(AgentSkills.frontmatterVersion(skill(version: "3")) == "3")
    }
}

@Suite struct CommandLineInstallTests {
    @Test func linksAndUnlinks() throws {
        let bin = FileManager.default.temporaryDirectory.appending(path: "bin-\(UUID().uuidString)", directoryHint: .isDirectory)
        let bundled = FileManager.default.temporaryDirectory.appending(path: "andyman-\(UUID().uuidString)")
        try "#!/bin/sh\n".write(to: bundled, atomically: true, encoding: .utf8)
        let other = FileManager.default.temporaryDirectory.appending(path: "andyman-other-\(UUID().uuidString)")

        #expect(CommandLineInstall.status(bundled: bundled, directory: bin) == .notInstalled)
        try CommandLineInstall.install(bundled: other, directory: bin)
        #expect(CommandLineInstall.status(bundled: bundled, directory: bin) == .otherCopy(other.standardizedFileURL.path))
        try CommandLineInstall.install(bundled: bundled, directory: bin)
        #expect(CommandLineInstall.status(bundled: bundled, directory: bin) == .installed)
        #expect(CommandLineInstall.isOnPath(bin, environment: ["PATH": "/usr/bin:\(bin.path)"]))
        #expect(!CommandLineInstall.isOnPath(bin, environment: ["PATH": "/usr/bin"]))

        try CommandLineInstall.uninstall(directory: bin)
        #expect(CommandLineInstall.status(bundled: bundled, directory: bin) == .notInstalled)
    }

    @Test func leavesARealFileAlone() throws {
        let bin = FileManager.default.temporaryDirectory.appending(path: "bin-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "someone else's".write(to: bin.appending(path: "andyman"), atomically: true, encoding: .utf8)
        let bundled = URL(fileURLWithPath: "/tmp/andyman")
        #expect(CommandLineInstall.status(bundled: bundled, directory: bin) == .conflict)
        #expect(throws: CommandLineInstallError.self) { try CommandLineInstall.install(bundled: bundled, directory: bin) }
        try CommandLineInstall.uninstall(directory: bin)
        #expect(FileManager.default.fileExists(atPath: bin.appending(path: "andyman").path))
    }

    @Test func shellBlockAddsLocalBin() {
        let lines = ShellExports.lines(sdkPath: "/sdk", java: nil, shell: .zsh, homeDirectory: "/Users/me", includeCommandLineTool: true)
        #expect(lines.last == "export PATH=\"$HOME/.local/bin:$PATH\"")
    }
}

@Suite struct AgentFeedbackTests {
    @Test func fixEncodesPlainly() throws {
        let data = try JSONEncoder().encode(ProjectFix.installPackages(["ndk;28.2.13676358"]))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["action"] as? String == "install_packages")
        #expect(json?["packages"] as? [String] == ["ndk;28.2.13676358"])
        for fix in [ProjectFix.useJDK(17), .installJDK(21), .writeLocalProperties(sdkPath: "/sdk")] {
            #expect(try JSONDecoder().decode(ProjectFix.self, from: JSONEncoder().encode(fix)) == fix)
        }
    }

    @Test func fillsMissingVariablesFromTheLoginShell() {
        let login = ["ANDROID_HOME": "/sdk", "JAVA_HOME": "/jdk", "PATH": "/usr/bin:/sdk/platform-tools", "SECRET": "x"]
        let overlay = LoginEnvironment.overlay(["PATH": "/usr/bin", "HOME": "/Users/me"]) { login }
        #expect(overlay.environment["ANDROID_HOME"] == "/sdk")
        #expect(overlay.environment["JAVA_HOME"] == "/jdk")
        #expect(overlay.environment["PATH"] == "/usr/bin:/sdk/platform-tools")
        #expect(overlay.environment["SECRET"] == nil)
        #expect(overlay.fromProfile == ["ANDROID_HOME", "JAVA_HOME", "PATH"])

        // Nothing missing, CI, or opted out: the environment is left as it is.
        let complete = ["ANDROID_HOME": "/mine", "JAVA_HOME": "/myjdk"]
        #expect(LoginEnvironment.overlay(complete) { login }.fromProfile.isEmpty)
        #expect(LoginEnvironment.overlay(["CI": "true"]) { login }.environment["ANDROID_HOME"] == nil)
        #expect(LoginEnvironment.overlay(["ANDYMAN_NO_SHELL_ENV": "1"]) { login }.environment["ANDROID_HOME"] == nil)
    }

    @Test func findsOtherJavaHomeLines() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "zshrc-\(UUID().uuidString)")
        try """
        export JAVA_HOME=$(/usr/libexec/java_home -v 24)
        # >>> Andyman >>>
        export JAVA_HOME=$(/usr/libexec/java_home -v 17)
        # <<< Andyman <<<
        JAVA_HOME=/late
        export JAVA_HOMEX=1
        """.write(to: file, atomically: true, encoding: .utf8)
        let others = ShellProfileEditor(file: file).otherAssignments(of: "JAVA_HOME")
        #expect(others.map(\.line) == [1, 5])
        #expect(others.map(\.overridesBlock) == [false, true])
    }
}

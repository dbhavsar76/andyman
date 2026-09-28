import Foundation

/// Generates the shell lines that make `ANDROID_HOME`, `JAVA_HOME` and the SDK tools available
/// in a terminal — what React Native's CLI and Gradle expect.
public enum ShellExports {
    public enum Shell: String, Sendable, CaseIterable, Codable {
        case zsh, bash, fish

        /// Picks the shell from a `$SHELL` path, defaulting to zsh (the macOS default).
        public init(shellPath: String?) {
            let name = shellPath.map { ($0 as NSString).lastPathComponent } ?? ""
            self = Shell(rawValue: name) ?? .zsh
        }

        public var profilePath: String {
            switch self {
            case .zsh: "~/.zshrc"
            case .bash: "~/.bash_profile"
            case .fish: "~/.config/fish/config.fish"
            }
        }
    }

    public static func lines(
        sdkPath: String?,
        java: JavaInstallation?,
        shell: Shell,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        includeCommandLineTool: Bool = CommandLineInstall.isLinked
    ) -> [String] {
        var lines: [String] = []
        if let java {
            // `java_home -v` keeps working across patch updates of the same major version.
            let value = if java.source == .javaHomeTool, let major = java.majorVersion {
                "$(/usr/libexec/java_home -v \(major))"
            } else {
                quoted(homeRelative(java.home, homeDirectory: homeDirectory))
            }
            lines.append(export("JAVA_HOME", value, shell: shell))
        }
        if let sdkPath {
            lines.append(export("ANDROID_HOME", quoted(homeRelative(sdkPath, homeDirectory: homeDirectory)), shell: shell))
            let tools = ["emulator", "platform-tools", "cmdline-tools/latest/bin"]
            switch shell {
            case .zsh, .bash:
                lines.append("export PATH=\"$PATH:" + tools.map { "$ANDROID_HOME/\($0)" }.joined(separator: ":") + "\"")
            case .fish:
                lines.append("fish_add_path --append " + tools.map { "\"$ANDROID_HOME/\($0)\"" }.joined(separator: " "))
            }
        }
        // `andyman` is linked into ~/.local/bin, which isn't on macOS's default PATH.
        if includeCommandLineTool {
            switch shell {
            case .zsh, .bash: lines.append("export PATH=\"$HOME/.local/bin:$PATH\"")
            case .fish: lines.append("fish_add_path \"$HOME/.local/bin\"")
            }
        }
        return lines
    }

    private static func export(_ name: String, _ value: String, shell: Shell) -> String {
        switch shell {
        case .zsh, .bash: "export \(name)=\(value)"
        case .fish: "set -gx \(name) \(value)"
        }
    }

    private static func homeRelative(_ path: String, homeDirectory: String) -> String {
        guard path == homeDirectory || path.hasPrefix(homeDirectory + "/") else { return path }
        return "$HOME" + path.dropFirst(homeDirectory.count)
    }

    private static func quoted(_ value: String) -> String {
        value.contains(" ") ? "\"\(value)\"" : value
    }
}

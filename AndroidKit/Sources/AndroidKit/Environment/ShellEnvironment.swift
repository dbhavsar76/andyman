import Foundation

/// Captures the environment a user's login shell would have.
///
/// Apps launched from Finder or the Dock inherit launchd's minimal environment, so
/// `ANDROID_HOME`, `JAVA_HOME` and a customised `PATH` from `~/.zshrc` are missing.
/// Running the login shell once and dumping `env` recovers them.
public enum ShellEnvironment {
    static let startMarker = "__ANDYMAN_ENV_START__"
    static let endMarker = "__ANDYMAN_ENV_END__"

    /// Runs `$SHELL -l -i -c env` and returns the resulting variables, or `nil` if the shell
    /// failed or took longer than `timeout` (slow or broken dotfiles shouldn't block us).
    public static func capture(
        shell: String? = nil,
        timeout: Duration = .seconds(5),
        runner: ProcessRunner = ProcessRunner()
    ) async -> [String: String]? {
        let shellPath = shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Markers let us ignore anything the dotfiles print (banners, prompt setup codes).
        let script = "printf '\(startMarker)'; /usr/bin/env -0; printf '\(endMarker)'"
        guard let result = try? await runner.run(
            URL(fileURLWithPath: shellPath),
            arguments: ["-l", "-i", "-c", script],
            timeout: timeout
        ) else { return nil }
        return parse(result.stdout)
    }

    /// Extracts NUL-separated `KEY=value` pairs between the markers.
    static func parse(_ output: Data) -> [String: String]? {
        let text = String(decoding: output, as: UTF8.self)
        guard let start = text.range(of: startMarker),
              let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex)
        else { return nil }

        var environment: [String: String] = [:]
        for entry in text[start.upperBound..<end.lowerBound].split(separator: "\0") {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<equals])
            guard !key.isEmpty else { continue }
            environment[key] = String(entry[entry.index(after: equals)...])
        }
        return environment
    }

    /// Splits a `PATH`-style value into its directories.
    public static func pathEntries(_ environment: [String: String]) -> [String] {
        (environment["PATH"] ?? "").split(separator: ":").map { expandTilde(String($0)) }
    }

    public static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

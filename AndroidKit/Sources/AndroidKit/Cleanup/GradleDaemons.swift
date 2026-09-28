import Darwin
import Foundation

/// A background JVM that Gradle or Kotlin keeps around to speed up builds.
public struct GradleDaemon: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case gradle, kotlin
    }

    public var pid: Int32
    public var kind: Kind
    public var version: String?
    /// Resident memory, in bytes.
    public var memory: Int64

    public var id: Int32 { pid }
}

public enum GradleDaemons {
    /// Running Gradle and Kotlin compile daemons, from `ps`.
    public static func running(runner: ProcessRunner = ProcessRunner()) async -> [GradleDaemon] {
        guard let result = try? await runner.run(
            URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axww", "-o", "pid=,rss=,command="],
            timeout: .seconds(10)
        ), result.succeeded else { return [] }
        return parse(result.stdoutString)
    }

    static func parse(_ output: String) -> [GradleDaemon] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let rss = Int64(fields[1]) else { return nil }
            let command = String(fields[2])
            let kind: GradleDaemon.Kind
            if command.contains("org.gradle.launcher.daemon.bootstrap.GradleDaemon") {
                kind = .gradle
            } else if command.contains("org.jetbrains.kotlin.daemon.KotlinCompileDaemon") {
                kind = .kotlin
            } else {
                return nil
            }
            return GradleDaemon(pid: pid, kind: kind, version: version(in: command, kind: kind), memory: rss * 1024)
        }
    }

    /// Gradle's version from its jars on the classpath (`gradle-daemon-main-8.14.3.jar`,
    /// `gradle-launcher-8.5.jar`), or Kotlin's from `kotlin-compiler-embeddable-2.1.20.jar`.
    static func version(in command: String, kind: GradleDaemon.Kind) -> String? {
        let pattern = switch kind {
        case .gradle: #"gradle-(?:daemon-main|launcher)-([0-9][\w.\-]*?)\.jar"#
        case .kotlin: #"kotlin-(?:compiler-embeddable|daemon)-([0-9][\w.\-]*?)\.jar"#
        }
        guard let range = command.range(of: pattern, options: .regularExpression) else { return nil }
        let match = String(command[range])
        return match.range(of: #"[0-9][\w.\-]*?(?=\.jar)"#, options: .regularExpression).map { String(match[$0]) }
    }

    /// Asks daemons to exit (SIGTERM, what `gradle --stop` amounts to), then force-quits any
    /// still running after `grace`. Returns how many stopped.
    @discardableResult
    public static func stop(_ daemons: [GradleDaemon], grace: Duration = .seconds(5)) async -> Int {
        for daemon in daemons { kill(daemon.pid, SIGTERM) }
        let deadline = ContinuousClock.now + grace
        var remaining = daemons.filter { DetachedProcess.isRunning($0.pid) }
        while !remaining.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            remaining = remaining.filter { DetachedProcess.isRunning($0.pid) }
        }
        for daemon in remaining { kill(daemon.pid, SIGKILL) }
        return daemons.count
    }
}

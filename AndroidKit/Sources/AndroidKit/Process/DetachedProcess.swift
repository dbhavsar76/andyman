import Darwin
import Foundation

/// Launches long-lived processes (emulators) that outlive the caller.
///
/// The child gets its own session (`setsid`), so quitting the app or finishing a CLI command
/// doesn't take it down, and its output goes to a log file instead of a pipe nobody reads.
public enum DetachedProcess {
    /// Spawns `executable` and returns its PID.
    ///
    /// - Parameter logFile: stdout and stderr are written here (truncated first).
    public static func spawn(
        _ executable: URL,
        arguments: [String],
        environment: [String: String],
        logFile: URL,
        currentDirectory: URL? = nil
    ) throws -> pid_t {
        try FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, logFile.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&fileActions, STDOUT_FILENO, STDERR_FILENO)
        if let currentDirectory {
            posix_spawn_file_actions_addchdir(&fileActions, currentDirectory.path)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // New session: detached from our process group and controlling terminal.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = [executable.path] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }

        var pid: pid_t = 0
        let status = withCStrings(argv) { argvPointers in
            withCStrings(envp) { envPointers in
                posix_spawn(&pid, executable.path, &fileActions, &attributes, argvPointers, envPointers)
            }
        }
        guard status == 0 else {
            throw ProcessError.launchFailed(
                executable: executable.lastPathComponent,
                reason: String(cString: strerror(status))
            )
        }

        // Reap the child when it exits so it doesn't linger as a zombie while we're running.
        // If we exit first, launchd adopts and reaps it.
        let childPID = pid
        Thread.detachNewThread {
            var exitStatus: Int32 = 0
            waitpid(childPID, &exitStatus, 0)
        }
        return pid
    }

    /// Whether a process with this PID exists (even if it belongs to another user).
    public static func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}

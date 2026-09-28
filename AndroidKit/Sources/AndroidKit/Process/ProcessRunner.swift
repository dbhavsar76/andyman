import Foundation
import Synchronization

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public var succeeded: Bool { exitCode == 0 }
    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessEvent: Sendable, Equatable {
    case stdout(String)
    case stderr(String)
    case exited(Int32)
}

public enum ProcessError: Error, Sendable, Equatable, LocalizedError {
    case launchFailed(executable: String, reason: String)
    case timedOut(executable: String)

    public var errorDescription: String? {
        switch self {
        case let .launchFailed(executable, reason):
            "Couldn't launch \(executable): \(reason)"
        case let .timedOut(executable):
            "\(executable) didn't finish in time."
        }
    }
}

/// Runs external tools (`adb`, `emulator`, `sdkmanager`, shells) with async APIs.
///
/// Output is collected until the process exits, then for a short grace period. We deliberately
/// don't wait for EOF on the pipes: tools like `adb` fork a long-lived server that inherits
/// stdout/stderr, so EOF may never arrive.
public struct ProcessRunner: Sendable {
    /// How long to keep reading after exit when the pipes are still open.
    public var drainGracePeriod: Duration

    public init(drainGracePeriod: Duration = .milliseconds(250)) {
        self.drainGracePeriod = drainGracePeriod
    }

    /// Runs a process to completion and returns its exit code and output.
    ///
    /// A non-zero exit code is not an error; check `ProcessResult.succeeded`.
    /// Cancelling the calling task terminates the process.
    public func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        standardInput: Data? = nil,
        timeout: Duration? = nil
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let stdout = Mutex(Data())
        let stderr = Mutex(Data())

        let execution = ProcessExecution(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            standardInput: standardInput,
            drainGracePeriod: drainGracePeriod,
            onStdout: { data in stdout.withLock { $0.append(data) } },
            onStderr: { data in stderr.withLock { $0.append(data) } }
        )

        let outcome = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                execution.onFinish = { continuation.resume(with: $0) }
                execution.start(timeout: timeout)
            }
        } onCancel: {
            execution.terminate()
        }

        try Task.checkCancellation()
        return ProcessResult(
            exitCode: outcome,
            stdout: stdout.withLock { $0 },
            stderr: stderr.withLock { $0 }
        )
    }

    /// Streams a process's output line by line, ending with `.exited(code)`.
    ///
    /// Lines are split on `\n` and `\r`, so progress bars redrawn with carriage returns arrive as
    /// separate lines. Cancelling iteration terminates the process.
    public func lines(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        standardInput: Data? = nil,
        timeout: Duration? = nil
    ) -> AsyncThrowingStream<ProcessEvent, any Error> {
        AsyncThrowingStream { continuation in
            let buffers = Mutex((stdout: LineBuffer(), stderr: LineBuffer()))

            let execution = ProcessExecution(
                executable: executable,
                arguments: arguments,
                environment: environment,
                currentDirectory: currentDirectory,
                standardInput: standardInput,
                drainGracePeriod: drainGracePeriod,
                onStdout: { data in
                    for line in buffers.withLock({ $0.stdout.append(data) }) {
                        continuation.yield(.stdout(line))
                    }
                },
                onStderr: { data in
                    for line in buffers.withLock({ $0.stderr.append(data) }) {
                        continuation.yield(.stderr(line))
                    }
                }
            )

            execution.onFinish = { result in
                let (lastOut, lastErr) = buffers.withLock { ($0.stdout.finish(), $0.stderr.finish()) }
                if let lastOut { continuation.yield(.stdout(lastOut)) }
                if let lastErr { continuation.yield(.stderr(lastErr)) }
                switch result {
                case let .success(code):
                    continuation.yield(.exited(code))
                    continuation.finish()
                case let .failure(error):
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in execution.terminate() }
            execution.start(timeout: timeout)
        }
    }
}

/// One launched process and the bookkeeping to decide when it's done.
///
/// `Process` isn't `Sendable`; all mutable state is guarded by `state`, and the `Process`
/// itself is only touched before launch and via thread-safe calls (`terminate`, `isRunning`).
private final class ProcessExecution: @unchecked Sendable {
    private struct State {
        var stdoutClosed = false
        var stderrClosed = false
        var exitCode: Int32?
        var timedOut = false
        var finished = false
        var onFinish: (@Sendable (Result<Int32, any Error>) -> Void)?
    }

    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let standardInput: Data?
    private let drainGracePeriod: Duration
    private let onStdout: @Sendable (Data) -> Void
    private let onStderr: @Sendable (Data) -> Void
    private let state = Mutex(State())

    var onFinish: (@Sendable (Result<Int32, any Error>) -> Void)? {
        get { state.withLock { $0.onFinish } }
        set { state.withLock { $0.onFinish = newValue } }
    }

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: URL?,
        standardInput: Data?,
        drainGracePeriod: Duration,
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void
    ) {
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        self.standardInput = standardInput
        self.drainGracePeriod = drainGracePeriod
        self.onStdout = onStdout
        self.onStderr = onStderr
    }

    func start(timeout: Duration?) {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.update { $0.stdoutClosed = true }
            } else {
                self?.onStdout(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.update { $0.stderrClosed = true }
            } else {
                self?.onStderr(data)
            }
        }
        process.terminationHandler = { [weak self] process in
            self?.didExit(process.terminationStatus)
        }

        let inputPipe: Pipe?
        if standardInput != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inputPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            inputPipe = nil
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let name = process.executableURL?.lastPathComponent ?? "process"
            finish(.failure(ProcessError.launchFailed(executable: name, reason: error.localizedDescription)))
            return
        }

        if let inputPipe, let standardInput {
            let writer = inputPipe.fileHandleForWriting
            DispatchQueue.global(qos: .userInitiated).async {
                // The process may exit without reading everything; a write error just means
                // it didn't want the rest of the input.
                try? writer.write(contentsOf: standardInput)
                try? writer.close()
            }
        }

        if let timeout {
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.timeOut()
            }
        }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    private func timeOut() {
        let shouldTerminate = state.withLock { state -> Bool in
            guard state.exitCode == nil, !state.finished else { return false }
            state.timedOut = true
            return true
        }
        if shouldTerminate { terminate() }
    }

    private func didExit(_ code: Int32) {
        update { $0.exitCode = code }
        // Give buffered output a moment to arrive if a forked child still holds the pipes.
        Task { [weak self, drainGracePeriod] in
            try? await Task.sleep(for: drainGracePeriod)
            self?.finishAfterExit()
        }
    }

    /// Records a state change and finishes once the process exited and both pipes closed.
    private func update(_ change: (inout State) -> Void) {
        let result: Result<Int32, any Error>? = state.withLock { state in
            change(&state)
            guard let code = state.exitCode, state.stdoutClosed, state.stderrClosed else { return nil }
            return outcome(code: code, timedOut: state.timedOut)
        }
        if let result { finish(result) }
    }

    private func finishAfterExit() {
        let result: Result<Int32, any Error>? = state.withLock { state in
            guard let code = state.exitCode else { return nil }
            return outcome(code: code, timedOut: state.timedOut)
        }
        if let result { finish(result) }
    }

    private func outcome(code: Int32, timedOut: Bool) -> Result<Int32, any Error> {
        if timedOut {
            let name = process.executableURL?.lastPathComponent ?? "process"
            return .failure(ProcessError.timedOut(executable: name))
        }
        return .success(code)
    }

    private func finish(_ result: Result<Int32, any Error>) {
        let callback = state.withLock { state -> (@Sendable (Result<Int32, any Error>) -> Void)? in
            guard !state.finished else { return nil }
            state.finished = true
            defer { state.onFinish = nil }
            return state.onFinish
        }
        guard let callback else { return }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        callback(result)
    }
}

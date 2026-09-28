import Foundation
import Testing
@testable import AndroidKit

@Suite struct LineBufferTests {
    @Test func splitsOnNewlinesAndCarriageReturns() {
        var buffer = LineBuffer()
        #expect(buffer.append(Data("a\nb\r\nc\rd".utf8)) == ["a", "b", "c"])
        #expect(buffer.finish() == "d")
        #expect(buffer.finish() == nil)
    }

    @Test func keepsPartialLinesAcrossChunks() {
        var buffer = LineBuffer()
        #expect(buffer.append(Data("[==   ] 4".utf8)).isEmpty)
        #expect(buffer.append(Data("0%\r[=====] 100%\n".utf8)) == ["[==   ] 40%", "[=====] 100%"])
    }

    @Test func crlfSplitAcrossChunksIsOneLineBreak() {
        var buffer = LineBuffer()
        #expect(buffer.append(Data("a\r".utf8)) == ["a"])
        #expect(buffer.append(Data("\nb\n".utf8)) == ["b"])
    }

    @Test func decodesMultibyteCharactersSplitAcrossChunks() {
        let bytes = Array("é\n".utf8)
        var buffer = LineBuffer()
        #expect(buffer.append(Data(bytes[..<1])).isEmpty)
        #expect(buffer.append(Data(bytes[1...])) == ["é"])
    }
}

@Suite struct ProcessRunnerTests {
    let runner = ProcessRunner()
    let shell = URL(fileURLWithPath: "/bin/sh")

    @Test func capturesOutputAndExitCode() async throws {
        let result = try await runner.run(shell, arguments: ["-c", "echo out; echo err >&2; exit 3"])
        #expect(result.exitCode == 3)
        #expect(result.stdoutString == "out\n")
        #expect(result.stderrString == "err\n")
    }

    @Test func passesStandardInput() async throws {
        let result = try await runner.run(URL(fileURLWithPath: "/bin/cat"), standardInput: Data("y\ny\n".utf8))
        #expect(result.stdoutString == "y\ny\n")
    }

    @Test func passesEnvironment() async throws {
        let result = try await runner.run(shell, arguments: ["-c", "printf %s \"$AMCTL_TEST\""], environment: ["AMCTL_TEST": "hello"])
        #expect(result.stdoutString == "hello")
    }

    /// Mirrors `adb` starting its server: a background child keeps the pipes open after exit.
    @Test func returnsWhenForkedChildHoldsPipesOpen() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await runner.run(shell, arguments: ["-c", "sleep 5 & echo started"])
        #expect(result.stdoutString == "started\n")
        #expect(clock.now - start < .seconds(2))
    }

    @Test func timesOut() async throws {
        await #expect(throws: ProcessError.timedOut(executable: "sh")) {
            try await runner.run(shell, arguments: ["-c", "sleep 5"], timeout: .milliseconds(200))
        }
    }

    @Test func reportsLaunchFailure() async throws {
        await #expect(throws: ProcessError.self) {
            try await runner.run(URL(fileURLWithPath: "/nonexistent/tool"))
        }
    }

    @Test func cancellationTerminatesProcess() async throws {
        let task = Task { try await runner.run(shell, arguments: ["-c", "sleep 5"]) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func streamsLines() async throws {
        var events: [ProcessEvent] = []
        for try await event in runner.lines(shell, arguments: ["-c", "printf 'one\\ntwo\\r'; printf 'oops\\n' >&2; printf tail; exit 1"]) {
            events.append(event)
        }
        #expect(events.filter { if case .stdout = $0 { true } else { false } } == [.stdout("one"), .stdout("two"), .stdout("tail")])
        #expect(events.contains(.stderr("oops")))
        #expect(events.last == .exited(1))
    }
}

import Foundation
import Testing
@testable import AeroSpacePreview

@Suite struct AsyncProcessRunnerTests {
    private let shellURL = URL(fileURLWithPath: "/bin/sh")

    @Test func drainsLargeStdoutAndStderrConcurrently() async throws {
        let runner = makeRunner(timeout: 5, stdoutLimit: 1_000_000, stderrLimit: 1_000_000)
        let script = """
        i=0
        while [ "$i" -lt 8000 ]; do
            printf 'out-%04d\n' "$i"
            printf 'err-%04d\n' "$i" >&2
            i=$((i + 1))
        done
        """

        let output = try await runner.run(executableURL: shellURL, arguments: ["-c", script])
        let stdout = String(decoding: output.stdout, as: UTF8.self)
        let stderr = String(decoding: output.stderr, as: UTF8.self)

        #expect(output.exitCode == 0)
        #expect(stdout.split(separator: "\n").count == 8000)
        #expect(stderr.split(separator: "\n").count == 8000)
        #expect(stdout.hasSuffix("out-7999\n"))
        #expect(stderr.hasSuffix("err-7999\n"))
    }

    @Test func preservesNonzeroExitAndStderr() async throws {
        let runner = makeRunner()
        let output = try await runner.run(
            executableURL: shellURL,
            arguments: ["-c", "printf 'specific failure\\n' >&2; exit 7"]
        )

        #expect(output.exitCode == 7)
        #expect(String(decoding: output.stderr, as: UTF8.self) == "specific failure\n")
    }

    @Test func timeoutEscalatesWhenProcessIgnoresTermination() async {
        let runner = makeRunner(timeout: 0.05, terminationGracePeriod: 0.05)
        let clock = ContinuousClock()
        let start = clock.now

        do {
            _ = try await runner.run(
                executableURL: shellURL,
                arguments: ["-c", "trap '' TERM; while :; do :; done"]
            )
            Issue.record("Expected the process to time out")
        } catch let error as AsyncProcessRunnerError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(start.duration(to: clock.now) < .seconds(1))
    }

    @Test func cancellationTerminatesAndAwaitsProcessCleanup() async {
        let runner = makeRunner(timeout: 5, terminationGracePeriod: 0.05)
        let task = Task {
            try await runner.run(
                executableURL: shellURL,
                arguments: ["-c", "trap '' TERM; while :; do :; done"]
            )
        }
        try? await Task.sleep(for: .milliseconds(50))
        let clock = ContinuousClock()
        let cancellationStart = clock.now
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected only after the child has exited and both drains finish.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(cancellationStart.duration(to: clock.now) < .seconds(1))
    }

    @Test func enforcesIndependentOutputLimits() async {
        let stdoutRunner = makeRunner(stdoutLimit: 32, stderrLimit: 1_000)
        await expectOutputLimit(
            runner: stdoutRunner,
            script: "i=0; while [ \"$i\" -lt 100 ]; do printf '0123456789'; i=$((i + 1)); done",
            stream: .stdout,
            limit: 32
        )

        let stderrRunner = makeRunner(stdoutLimit: 1_000, stderrLimit: 24)
        await expectOutputLimit(
            runner: stderrRunner,
            script: "i=0; while [ \"$i\" -lt 100 ]; do printf 'abcdefghij' >&2; i=$((i + 1)); done",
            stream: .stderr,
            limit: 24
        )
    }

    private func expectOutputLimit(
        runner: AsyncProcessRunner,
        script: String,
        stream: ProcessOutputStream,
        limit: Int
    ) async {
        do {
            let output = try await runner.run(executableURL: shellURL, arguments: ["-c", script])
            Issue.record("Expected \(stream.rawValue) to exceed its limit (captured stdout=\(output.stdout.count), stderr=\(output.stderr.count))")
        } catch let error as AsyncProcessRunnerError {
            #expect(error == .outputLimitExceeded(stream: stream, limit: limit))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func makeRunner(
        timeout: TimeInterval = 2,
        terminationGracePeriod: TimeInterval = 0.05,
        stdoutLimit: Int = 1_000,
        stderrLimit: Int = 1_000
    ) -> AsyncProcessRunner {
        AsyncProcessRunner(configuration: .init(
            timeout: timeout,
            terminationGracePeriod: terminationGracePeriod,
            stdoutLimit: stdoutLimit,
            stderrLimit: stderrLimit
        ))
    }
}

@Suite struct AeroSpaceProcessErrorClassificationTests {
    @Test func recognizesVerifiedServerUnavailableMessage() {
        #expect(AeroSpaceClient.stderrMeansServerNotRunning(
            "Can't connect to AeroSpace server. Is AeroSpace.app running?"
        ))
        #expect(AeroSpaceClient.stderrMeansServerNotRunning(
            "CAN'T CONNECT TO AEROSPACE SERVER. IS AEROSPACE.APP RUNNING?"
        ))
    }

    @Test func doesNotTreatEveryServerErrorAsNotRunning() {
        #expect(!AeroSpaceClient.stderrMeansServerNotRunning("Failed to parse server response"))
        #expect(!AeroSpaceClient.stderrMeansServerNotRunning("server returned malformed data"))
    }
}

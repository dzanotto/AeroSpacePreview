import Darwin
import Foundation

enum ProcessOutputStream: String, Sendable {
    case stdout
    case stderr
}

enum AsyncProcessRunnerError: Error, Equatable, Sendable {
    case launchFailed(String)
    case timedOut
    case outputLimitExceeded(stream: ProcessOutputStream, limit: Int)
    case pipeReadFailed(stream: ProcessOutputStream, message: String)
}

struct AsyncProcessOutput: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
}

/// Runs a subprocess without blocking the calling task. An execution owns the
/// child until it has exited and both output pipes have reached EOF.
struct AsyncProcessRunner: Sendable {
    struct Configuration: Sendable {
        var timeout: TimeInterval
        var terminationGracePeriod: TimeInterval
        var stdoutLimit: Int
        var stderrLimit: Int

        init(
            timeout: TimeInterval,
            terminationGracePeriod: TimeInterval = 0.3,
            stdoutLimit: Int,
            stderrLimit: Int
        ) {
            self.timeout = timeout
            self.terminationGracePeriod = terminationGracePeriod
            self.stdoutLimit = stdoutLimit
            self.stderrLimit = stderrLimit
        }
    }

    let configuration: Configuration

    func run(executableURL: URL, arguments: [String]) async throws -> AsyncProcessOutput {
        try Task.checkCancellation()

        let execution = ProcessExecution(
            executableURL: executableURL,
            arguments: arguments,
            configuration: configuration
        )
        try execution.start()

        return try await withTaskCancellationHandler {
            try await execution.result()
        } onCancel: {
            execution.cancel()
        }
    }
}

private final class ProcessExecution: @unchecked Sendable {
    private enum StopReason {
        case cancelled
        case timedOut
        case outputLimitExceeded(stream: ProcessOutputStream, limit: Int)
        case pipeReadFailed(stream: ProcessOutputStream, message: String)
    }

    private static let workerQueue = DispatchQueue(
        label: "AeroSpacePreview.AsyncProcessRunner",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let readChunkSize = 64 * 1024

    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let configuration: AsyncProcessRunner.Configuration
    private let group = DispatchGroup()
    private let lock = NSLock()

    private var stdout = Data()
    private var stderr = Data()
    private var processExited = false
    private var stopReason: StopReason?
    private var didSendTerminate = false
    private var timeoutWorkItem: DispatchWorkItem?
    private var escalationWorkItem: DispatchWorkItem?
    private var continuation: CheckedContinuation<AsyncProcessOutput, Error>?
    private var completedResult: Result<AsyncProcessOutput, Error>?

    init(
        executableURL: URL,
        arguments: [String],
        configuration: AsyncProcessRunner.Configuration
    ) {
        self.configuration = configuration
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func start() throws {
        do {
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            throw AsyncProcessRunnerError.launchFailed(String(describing: error))
        }

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.requestStop(.timedOut)
        }
        lock.withLock {
            self.timeoutWorkItem = timeoutWorkItem
        }
        Self.workerQueue.asyncAfter(
            deadline: .now() + max(0, configuration.timeout),
            execute: timeoutWorkItem
        )

        startReader(
            handle: stdoutPipe.fileHandleForReading,
            stream: .stdout,
            limit: configuration.stdoutLimit
        )
        startReader(
            handle: stderrPipe.fileHandleForReading,
            stream: .stderr,
            limit: configuration.stderrLimit
        )

        group.enter()
        Self.workerQueue.async { [self] in
            process.waitUntilExit()
            lock.withLock {
                processExited = true
            }
            group.leave()
        }

        group.notify(queue: Self.workerQueue) { [self] in
            finish()
        }
    }

    func result() async throws -> AsyncProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            let completedResult = lock.withLock { () -> Result<AsyncProcessOutput, Error>? in
                if let completedResult = self.completedResult {
                    return completedResult
                }
                self.continuation = continuation
                return nil
            }
            if let completedResult {
                continuation.resume(with: completedResult)
            }
        }
    }

    func cancel() {
        requestStop(.cancelled)
    }

    private func startReader(
        handle: FileHandle,
        stream: ProcessOutputStream,
        limit: Int
    ) {
        group.enter()
        Self.workerQueue.async { [self] in
            var captured = Data()
            var didExceedLimit = false

            do {
                while let chunk = try handle.read(upToCount: Self.readChunkSize), !chunk.isEmpty {
                    let remaining = max(0, limit - captured.count)
                    if remaining > 0 {
                        captured.append(contentsOf: chunk.prefix(remaining))
                    }
                    if chunk.count > remaining, !didExceedLimit {
                        didExceedLimit = true
                        requestStop(.outputLimitExceeded(stream: stream, limit: limit))
                    }
                }
                store(captured, for: stream)
            } catch {
                store(captured, for: stream)
                requestStop(.pipeReadFailed(stream: stream, message: String(describing: error)))
            }

            group.leave()
        }
    }

    private func store(_ data: Data, for stream: ProcessOutputStream) {
        lock.withLock {
            switch stream {
            case .stdout:
                stdout = data
            case .stderr:
                stderr = data
            }
        }
    }

    private func requestStop(_ reason: StopReason) {
        let escalationWorkItem = DispatchWorkItem { [weak self] in
            self?.forceTerminateIfNeeded()
        }
        let shouldTerminate = lock.withLock { () -> Bool in
            guard completedResult == nil, stopReason == nil else { return false }
            stopReason = reason
            guard !processExited, !didSendTerminate else { return false }
            didSendTerminate = true
            self.escalationWorkItem = escalationWorkItem
            return true
        }
        guard shouldTerminate else { return }

        Darwin.kill(process.processIdentifier, SIGTERM)
        Self.workerQueue.asyncAfter(
            deadline: .now() + max(0, configuration.terminationGracePeriod),
            execute: escalationWorkItem
        )
    }

    private func forceTerminateIfNeeded() {
        let shouldKill = lock.withLock { !processExited }
        if shouldKill {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    private func finish() {
        let completion = lock.withLock { () -> (
            CheckedContinuation<AsyncProcessOutput, Error>?,
            Result<AsyncProcessOutput, Error>
        ) in
            timeoutWorkItem?.cancel()
            escalationWorkItem?.cancel()

            let result: Result<AsyncProcessOutput, Error>
            switch stopReason {
            case .cancelled:
                result = .failure(CancellationError())
            case .timedOut:
                result = .failure(AsyncProcessRunnerError.timedOut)
            case .outputLimitExceeded(let stream, let limit):
                result = .failure(AsyncProcessRunnerError.outputLimitExceeded(stream: stream, limit: limit))
            case .pipeReadFailed(let stream, let message):
                result = .failure(AsyncProcessRunnerError.pipeReadFailed(stream: stream, message: message))
            case nil:
                result = .success(AsyncProcessOutput(
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: process.terminationStatus
                ))
            }

            completedResult = result
            let continuation = self.continuation
            self.continuation = nil
            return (continuation, result)
        }

        completion.0?.resume(with: completion.1)
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}

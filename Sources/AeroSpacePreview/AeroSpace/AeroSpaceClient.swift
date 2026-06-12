import CoreGraphics
import Foundation

/// Thin synchronous wrapper around the `aerospace` CLI. Callers that care
/// about latency (the overlay) invoke it off the main thread.
struct AeroSpaceClient: Sendable {
    let cliPath: String
    var timeout: TimeInterval = 2.0

    static let defaultSearchPaths = [
        "/opt/homebrew/bin/aerospace",
        "/usr/local/bin/aerospace",
    ]

    static func discover() throws -> AeroSpaceClient {
        var candidates = defaultSearchPaths
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            candidates += envPath.split(separator: ":").map { "\($0)/aerospace" }
        }
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AeroSpaceError.cliNotFound(searched: candidates)
        }
        return AeroSpaceClient(cliPath: found)
    }

    // MARK: - Queries

    func fetchSnapshot() async throws -> AeroSpaceSnapshot {
        // Each CLI invocation costs tens of ms of process overhead (measured
        // ~60-95 ms in M6); the three queries are independent, so run them
        // concurrently — the snapshot costs one round-trip, not three.
        let client = self
        let windowsTask = Task.detached {
            try client.run(["list-windows", "--all", "--format", AeroSpaceParser.windowFormat])
        }
        let focusedWorkspaceTask = Task.detached {
            try client.run(["list-workspaces", "--focused", "--format", "%{workspace}"])
        }
        // No focused window is a legal state (e.g. empty workspace).
        let focusedWindowTask = Task.detached {
            try? client.run(["list-windows", "--focused", "--format", "%{window-id}"])
        }

        let windowRows = try AeroSpaceParser.parseWindowRows(await windowsTask.value)
        let focusedWorkspace = try await focusedWorkspaceTask.value
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let focusedWindowID = await focusedWindowTask.value
            .flatMap { CGWindowID($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        return AeroSpaceParser.buildSnapshot(
            windowRows: windowRows,
            focusedWorkspace: focusedWorkspace,
            focusedWindowID: focusedWindowID
        )
    }

    // MARK: - Actions

    func switchToWorkspace(_ name: String) throws {
        _ = try run(["workspace", name])
    }

    func focusWindow(id: CGWindowID) throws {
        _ = try run(["focus", "--window-id", String(id)])
    }

    // MARK: - Process plumbing

    @discardableResult
    private func run(_ arguments: [String]) throws -> String {
        let commandLabel = "aerospace " + arguments.joined(separator: " ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw AeroSpaceError.cliNotFound(searched: [cliPath])
        }

        // Drain stdout on a background queue; EOF arrives when the process
        // exits, which doubles as our completion signal. Draining while the
        // process runs avoids pipe-buffer deadlock on large output.
        let outBox = LockedBox<Data>(Data())
        let done = DispatchSemaphore(value: 0)
        let outHandle = stdout.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            outBox.value = outHandle.readDataToEndOfFile()
            done.signal()
        }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw AeroSpaceError.timeout(command: commandLabel)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if errText.localizedCaseInsensitiveContains("server") {
                throw AeroSpaceError.serverNotRunning
            }
            throw AeroSpaceError.commandFailed(
                command: commandLabel,
                exitCode: process.terminationStatus,
                stderr: errText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return String(data: outBox.value, encoding: .utf8) ?? ""
    }
}

/// Minimal lock-guarded cell so the pipe-drain closure can hand data across
/// threads under Swift 6 strict concurrency.
private final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

import CoreGraphics
import Foundation

/// Async wrapper around the `aerospace` CLI.
struct AeroSpaceClient: Sendable {
    static let stdoutLimit = 4 * 1024 * 1024
    static let stderrLimit = 256 * 1024

    let cliPath: String
    var timeout: TimeInterval = 2.0

    static let defaultSearchPaths = [
        "/opt/homebrew/bin/aerospace",
        "/usr/local/bin/aerospace",
    ]

    static func discover(
        environmentPath: String? = ProcessInfo.processInfo.environment["PATH"],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) throws -> AeroSpaceClient {
        var candidates = defaultSearchPaths
        if let envPath = environmentPath {
            candidates += envPath.split(separator: ":").map { "\($0)/aerospace" }
        }
        guard let found = candidates.first(where: isExecutable) else {
            throw AeroSpaceError.cliNotFound(searched: candidates)
        }
        return AeroSpaceClient(cliPath: found)
    }

    // MARK: - Queries

    func fetchSnapshot() async throws -> AeroSpaceSnapshot {
        // Each CLI invocation has measurable process overhead; the three
        // queries are independent, so run them concurrently and make the
        // snapshot cost one round-trip instead of three.
        async let windowsOutput = run([
            "list-windows", "--all", "--format", AeroSpaceParser.windowFormat,
        ])
        async let focusedWorkspaceOutput = run([
            "list-workspaces", "--focused", "--format", "%{workspace}",
        ])
        // No focused window is a legal state (e.g. empty workspace).
        async let focusedWindowOutput = try? run([
            "list-windows", "--focused", "--format", "%{window-id}",
        ])

        let outputs = try await (windowsOutput, focusedWorkspaceOutput, focusedWindowOutput)
        let windowRows = try AeroSpaceParser.parseWindowRows(outputs.0)
        let focusedWorkspace = outputs.1
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let focusedWindowID = outputs.2
            .flatMap { CGWindowID($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        return AeroSpaceParser.buildSnapshot(
            windowRows: windowRows,
            focusedWorkspace: focusedWorkspace,
            focusedWindowID: focusedWindowID
        )
    }

    /// The focused workspace and its window IDs — the minimal query for a
    /// layout harvest after a workspace switch.
    func fetchFocusedWorkspaceWindows() async throws -> (workspace: String, windowIDs: [CGWindowID]) {
        async let workspaceOutput = run([
            "list-workspaces", "--focused", "--format", "%{workspace}",
        ])
        async let windowsOutput = run([
            "list-windows", "--workspace", "focused", "--format", "%{window-id}",
        ])
        let outputs = try await (workspaceOutput, windowsOutput)
        let workspace = outputs.0.trimmingCharacters(in: .whitespacesAndNewlines)
        let windowIDs = outputs.1
            .split(separator: "\n")
            .compactMap { CGWindowID($0.trimmingCharacters(in: .whitespaces)) }
        return (workspace, windowIDs)
    }

    // MARK: - Actions

    func switchToWorkspace(_ name: String) async throws {
        _ = try await run(["workspace", name])
    }

    func focusWindow(id: CGWindowID) async throws {
        _ = try await run(["focus", "--window-id", String(id)])
    }

    // MARK: - Process plumbing

    @discardableResult
    private func run(_ arguments: [String]) async throws -> String {
        let commandLabel = "aerospace " + arguments.joined(separator: " ")
        let runner = AsyncProcessRunner(configuration: .init(
            timeout: timeout,
            stdoutLimit: Self.stdoutLimit,
            stderrLimit: Self.stderrLimit
        ))
        let output: AsyncProcessOutput
        do {
            output = try await runner.run(
                executableURL: URL(fileURLWithPath: cliPath),
                arguments: arguments
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch AsyncProcessRunnerError.timedOut {
            throw AeroSpaceError.timeout(command: commandLabel)
        } catch AsyncProcessRunnerError.outputLimitExceeded(let stream, let limit) {
            throw AeroSpaceError.outputTooLarge(
                command: commandLabel,
                stream: stream.rawValue,
                limit: limit
            )
        } catch AsyncProcessRunnerError.launchFailed {
            throw AeroSpaceError.cliNotFound(searched: [cliPath])
        } catch {
            throw AeroSpaceError.commandFailed(
                command: commandLabel,
                exitCode: -1,
                stderr: String(describing: error)
            )
        }

        guard output.exitCode == 0 else {
            let errText = String(decoding: output.stderr, as: UTF8.self)
            if Self.stderrMeansServerNotRunning(errText) {
                throw AeroSpaceError.serverNotRunning
            }
            throw AeroSpaceError.commandFailed(
                command: commandLabel,
                exitCode: output.exitCode,
                stderr: errText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return String(decoding: output.stdout, as: UTF8.self)
    }

    static func stderrMeansServerNotRunning(_ stderr: String) -> Bool {
        stderr.range(
            of: "Can't connect to AeroSpace server. Is AeroSpace.app running?",
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }
}

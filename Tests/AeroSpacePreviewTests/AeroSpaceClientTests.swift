import CoreGraphics
import Foundation
import Testing
@testable import AeroSpacePreview

@Suite struct AeroSpaceClientTests {
    @Test func discoverySearchesDefaultLocationsBeforeTheProcessPath() throws {
        let client = try AeroSpaceClient.discover(
            environmentPath: "/custom/bin:/fallback/bin",
            isExecutable: { $0 == "/fallback/bin/aerospace" }
        )

        #expect(client.cliPath == "/fallback/bin/aerospace")

        do {
            _ = try AeroSpaceClient.discover(
                environmentPath: "/custom/bin:/fallback/bin",
                isExecutable: { _ in false }
            )
            Issue.record("Expected discovery to fail")
        } catch let error as AeroSpaceError {
            guard case .cliNotFound(let searched) = error else {
                Issue.record("Unexpected AeroSpace error: \(error)")
                return
            }
            #expect(searched == [
                "/opt/homebrew/bin/aerospace",
                "/usr/local/bin/aerospace",
                "/custom/bin/aerospace",
                "/fallback/bin/aerospace",
            ])
        }
    }

    @Test func fetchSnapshotUsesTheExpectedQueriesAndAssemblesTheirOutput() async throws {
        let cli = try FakeAeroSpaceCLI(body: """
        if [ "$1" = "list-windows" ] && [ "$2" = "--all" ]; then
            printf '10\tcom.editor\tEditor\t10\tMain\n20\tcom.browser\tBrowser\t2\tDocs\n'
        elif [ "$1" = "list-workspaces" ] && [ "$2" = "--focused" ]; then
            printf ' 2 \n'
        elif [ "$1" = "list-windows" ] && [ "$2" = "--focused" ]; then
            printf '20\n'
        else
            printf 'unexpected command\n' >&2
            exit 64
        fi
        """)
        let client = makeClient(for: cli)

        let snapshot = try await client.fetchSnapshot()

        #expect(snapshot.workspaces.map(\.name) == ["2", "10"])
        #expect(snapshot.focusedWorkspace?.name == "2")
        #expect(snapshot.allWindows.first(where: { $0.id == 20 })?.isFocused == true)
        #expect(Set(try cli.commands()) == Set([
            "list-windows|--all|--format|\(AeroSpaceParser.windowFormat)|",
            "list-workspaces|--focused|--format|%{workspace}|",
            "list-windows|--focused|--format|%{window-id}|",
        ]))
    }

    @Test func fetchSnapshotTreatsAFailedFocusedWindowQueryAsNoFocusedWindow() async throws {
        let cli = try FakeAeroSpaceCLI(body: """
        if [ "$1" = "list-windows" ] && [ "$2" = "--all" ]; then
            printf '10\tcom.editor\tEditor\tdev\tMain\n'
        elif [ "$1" = "list-workspaces" ]; then
            printf 'dev\n'
        elif [ "$1" = "list-windows" ] && [ "$2" = "--focused" ]; then
            printf 'no focused window\n' >&2
            exit 1
        else
            exit 64
        fi
        """)

        let snapshot = try await makeClient(for: cli).fetchSnapshot()

        #expect(snapshot.focusedWorkspace?.name == "dev")
        #expect(snapshot.allWindows.allSatisfy { !$0.isFocused })
    }

    @Test func focusedWorkspaceQueryAndActionsPreserveTheCommandProtocol() async throws {
        let cli = try FakeAeroSpaceCLI(body: """
        if [ "$1" = "list-workspaces" ]; then
            printf ' dev \n'
        elif [ "$1" = "list-windows" ] && [ "$2" = "--workspace" ]; then
            printf '12\nnot-an-id\n34 \n'
        elif [ "$1" = "workspace" ] || [ "$1" = "focus" ]; then
            :
        else
            exit 64
        fi
        """)
        let client = makeClient(for: cli)

        let focused = try await client.fetchFocusedWorkspaceWindows()
        try await client.switchToWorkspace("project notes")
        try await client.focusWindow(id: 42)

        #expect(focused.workspace == "dev")
        #expect(focused.windowIDs == [12, 34])
        #expect(Set(try cli.commands()) == Set([
            "list-workspaces|--focused|--format|%{workspace}|",
            "list-windows|--workspace|focused|--format|%{window-id}|",
            "workspace|project notes|",
            "focus|--window-id|42|",
        ]))
    }

    @Test func verifiedConnectionFailureMapsToServerNotRunning() async throws {
        let cli = try FakeAeroSpaceCLI(body: """
        printf "Can't connect to AeroSpace server. Is AeroSpace.app running?\n" >&2
        exit 1
        """)

        do {
            try await makeClient(for: cli).switchToWorkspace("dev")
            Issue.record("Expected the command to fail")
        } catch let error as AeroSpaceError {
            guard case .serverNotRunning = error else {
                Issue.record("Unexpected AeroSpace error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func genericCommandFailurePreservesCommandExitCodeAndTrimmedStderr() async throws {
        let cli = try FakeAeroSpaceCLI(body: """
        printf ' specific failure \n' >&2
        exit 7
        """)

        do {
            try await makeClient(for: cli).focusWindow(id: 99)
            Issue.record("Expected the command to fail")
        } catch let error as AeroSpaceError {
            guard case .commandFailed(let command, let exitCode, let stderr) = error else {
                Issue.record("Unexpected AeroSpace error: \(error)")
                return
            }
            #expect(command == "aerospace focus --window-id 99")
            #expect(exitCode == 7)
            #expect(stderr == "specific failure")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func runnerFailuresMapToPublicClientErrors() async throws {
        let hangingCLI = try FakeAeroSpaceCLI(body: """
        while :; do :; done
        """)
        var timingOutClient = AeroSpaceClient(cliPath: hangingCLI.executableURL.path)
        timingOutClient.timeout = 0.02

        do {
            try await timingOutClient.switchToWorkspace("dev")
            Issue.record("Expected the command to time out")
        } catch let error as AeroSpaceError {
            guard case .timeout(let command) = error else {
                Issue.record("Unexpected AeroSpace error: \(error)")
                return
            }
            #expect(command == "aerospace workspace dev")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("aerospace")
            .path
        do {
            try await AeroSpaceClient(cliPath: missingPath).switchToWorkspace("dev")
            Issue.record("Expected the missing executable to fail")
        } catch let error as AeroSpaceError {
            guard case .cliNotFound(let searched) = error else {
                Issue.record("Unexpected AeroSpace error: \(error)")
                return
            }
            #expect(searched == [missingPath])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func oversizedOutputReportsThePublicStreamAndLimit() async throws {
        let cli = try FakeAeroSpaceCLI(body: """
        /usr/bin/head -c 4194305 /dev/zero
        """)

        do {
            try await makeClient(for: cli).switchToWorkspace("dev")
            Issue.record("Expected stdout to exceed the client limit")
        } catch let error as AeroSpaceError {
            guard case .outputTooLarge(let command, let stream, let limit) = error else {
                Issue.record("Unexpected AeroSpace error: \(error)")
                return
            }
            #expect(command == "aerospace workspace dev")
            #expect(stream == "stdout")
            #expect(limit == AeroSpaceClient.stdoutLimit)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func makeClient(for cli: FakeAeroSpaceCLI) -> AeroSpaceClient {
        var client = AeroSpaceClient(cliPath: cli.executableURL.path)
        // Swift Testing runs suites concurrently; leave headroom for process
        // scheduling while keeping timeout translation covered separately.
        client.timeout = 10
        return client
    }
}

private final class FakeAeroSpaceCLI {
    let executableURL: URL

    private let directoryURL: URL
    private let logURL: URL

    init(body: String) throws {
        let fileManager = FileManager.default
        directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("AeroSpacePreviewTests-\(UUID().uuidString)", isDirectory: true)
        executableURL = directoryURL.appendingPathComponent("aerospace")
        logURL = directoryURL.appendingPathComponent("commands.log")

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        log_path=\(Self.shellQuote(logURL.path))
        command_line=
        for argument in "$@"; do
            command_line="${command_line}${argument}|"
        done
        printf '%s\n' "$command_line" >> "$log_path"
        \(body)
        """
        try Data(script.utf8).write(to: executableURL)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executableURL.path
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func commands() throws -> [String] {
        let text = try String(contentsOf: logURL, encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

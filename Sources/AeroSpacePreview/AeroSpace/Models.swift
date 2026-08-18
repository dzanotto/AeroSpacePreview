import CoreGraphics

/// A window as reported by AeroSpace. `id` is a CGWindowID, verified as
/// usable directly with ScreenCaptureKit.
struct AeroSpaceWindow: Codable, Equatable, Sendable {
    let id: CGWindowID
    let appName: String
    let bundleID: String
    let title: String
    var isFocused: Bool = false
}

struct AeroSpaceWorkspace: Codable, Equatable, Sendable {
    let name: String
    let isFocused: Bool
    let windows: [AeroSpaceWindow]
}

/// Immutable view of the requested AeroSpace state at one point in time,
/// natural-sorted by workspace name. Empty non-focused workspaces are present
/// only when the corresponding snapshot option is enabled.
struct AeroSpaceSnapshot: Codable, Equatable, Sendable {
    let workspaces: [AeroSpaceWorkspace]

    var focusedWorkspace: AeroSpaceWorkspace? {
        workspaces.first(where: \.isFocused)
    }

    var allWindows: [AeroSpaceWindow] {
        workspaces.flatMap(\.windows)
    }
}

enum AeroSpaceError: Error, CustomStringConvertible, Sendable {
    case cliNotFound(searched: [String])
    case serverNotRunning
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case timeout(command: String)
    case outputTooLarge(command: String, stream: String, limit: Int)
    case parseFailure(line: String)

    var description: String {
        switch self {
        case .cliNotFound(let searched):
            "aerospace CLI not found (searched: \(searched.joined(separator: ", ")))"
        case .serverNotRunning:
            "AeroSpace is not running"
        case .commandFailed(let command, let exitCode, let stderr):
            "`\(command)` failed (exit \(exitCode)): \(stderr)"
        case .timeout(let command):
            "`\(command)` timed out"
        case .outputTooLarge(let command, let stream, let limit):
            "`\(command)` produced more than \(limit) bytes on \(stream)"
        case .parseFailure(let line):
            "could not parse aerospace output line: \(line)"
        }
    }
}

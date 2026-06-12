import CoreGraphics
import Foundation

/// Pure parsing/assembly logic for `aerospace` CLI output — no process
/// spawning, fully unit-testable.
enum AeroSpaceParser {
    /// Field order of the `list-windows` --format string. Title comes last so
    /// that a title containing the separator can't break parsing (split is
    /// capped at fieldCount - 1).
    static let windowFormat = "%{window-id}\t%{app-bundle-id}\t%{app-name}\t%{workspace}\t%{window-title}"
    private static let windowFieldCount = 5

    struct WindowRow: Equatable {
        let window: AeroSpaceWindow
        let workspace: String
    }

    static func parseWindowRows(_ text: String) throws -> [WindowRow] {
        try text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            let fields = line.split(separator: "\t", maxSplits: windowFieldCount - 1,
                                    omittingEmptySubsequences: false)
            guard fields.count == windowFieldCount, let id = CGWindowID(fields[0]) else {
                throw AeroSpaceError.parseFailure(line: String(line))
            }
            return WindowRow(
                window: AeroSpaceWindow(
                    id: id,
                    appName: String(fields[2]),
                    bundleID: String(fields[1]),
                    title: String(fields[4])
                ),
                workspace: String(fields[3])
            )
        }
    }

    static func buildSnapshot(
        windowRows: [WindowRow],
        focusedWorkspace: String,
        focusedWindowID: CGWindowID?
    ) -> AeroSpaceSnapshot {
        var byWorkspace: [String: [AeroSpaceWindow]] = [:]
        for row in windowRows {
            var window = row.window
            window.isFocused = window.id == focusedWindowID
            byWorkspace[row.workspace, default: []].append(window)
        }
        byWorkspace[focusedWorkspace, default: []] += [] // focused shows even if empty

        let workspaces = byWorkspace
            .sorted { naturalLess($0.key, $1.key) }
            .map { name, windows in
                AeroSpaceWorkspace(name: name, isFocused: name == focusedWorkspace, windows: windows)
            }
        return AeroSpaceSnapshot(workspaces: workspaces)
    }

    /// Numeric-aware, case-insensitive ordering: "2" < "10", "ws2" < "ws10".
    static func naturalLess(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.numeric, .caseInsensitive]) == .orderedAscending
    }
}

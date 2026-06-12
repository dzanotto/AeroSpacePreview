// R1 spike: check that AeroSpace window-ids exist in the CGWindowList,
// and inspect bounds of windows on hidden workspaces.
import CoreGraphics
import AppKit

let aerospaceIDs: [CGWindowID] = CommandLine.arguments.dropFirst().compactMap { UInt32($0) }
guard !aerospaceIDs.isEmpty else {
    print("usage: r1_window_ids.swift <window-id>...")
    exit(1)
}

guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
    print("CGWindowListCopyWindowInfo failed")
    exit(1)
}

var byID: [CGWindowID: [String: Any]] = [:]
for w in info {
    if let id = w[kCGWindowNumber as String] as? UInt32 { byID[id] = w }
}

for id in aerospaceIDs {
    if let w = byID[id] {
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let bounds = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let onScreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
        print("MATCH \(id) owner=\(owner) onScreen=\(onScreen) bounds=(x:\(bounds["X"] ?? -1), y:\(bounds["Y"] ?? -1), w:\(bounds["Width"] ?? -1), h:\(bounds["Height"] ?? -1))")
    } else {
        print("MISS  \(id) — not found in CGWindowList")
    }
}

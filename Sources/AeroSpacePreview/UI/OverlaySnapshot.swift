import CoreGraphics

/// The AeroSpace state the overlay renders, assembled once per summon.
/// Immutable; thumbnails are published separately by the view model so the
/// overlay can appear before captures finish (placeholders fill the gap).
struct OverlaySnapshot: Sendable {
    let workspaces: [AeroSpaceWorkspace]
    let permissionDenied: Bool

    var allWindowIDs: [CGWindowID] {
        workspaces.flatMap(\.windows).map(\.id)
    }

    var focusedWorkspace: AeroSpaceWorkspace? {
        workspaces.first(where: \.isFocused)
    }
}

enum OverlayContent: Sendable {
    case snapshot(OverlaySnapshot)
    case error(String)
}

/// User intents flowing back from the SwiftUI layer to the controller.
struct OverlayActions {
    let dismiss: @MainActor () -> Void
    let selectWorkspace: @MainActor (String) -> Void
    let focusWindow: @MainActor (CGWindowID) -> Void
}

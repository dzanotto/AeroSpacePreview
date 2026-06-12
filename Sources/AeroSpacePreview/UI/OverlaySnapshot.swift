import CoreGraphics

/// Everything the overlay renders, assembled once per summon. Immutable —
/// thumbnails are static while the overlay is open (capture-on-summon).
struct OverlaySnapshot: Sendable {
    let workspaces: [AeroSpaceWorkspace]
    let thumbnails: [CGWindowID: CGImage]
    let permissionDenied: Bool
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

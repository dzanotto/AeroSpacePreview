import CoreGraphics
import SwiftUI

/// Stable per-window image state. Each thumbnail view observes only its own
/// slot, so a live frame does not invalidate every workspace tile.
@MainActor
final class ThumbnailStore {
    @MainActor
    final class Slot: ObservableObject {
        @Published private(set) var image: CGImage?

        fileprivate func update(_ image: CGImage?) {
            // Capture failures and non-displayable stream frames keep the
            // last good image instead of flashing back to a placeholder.
            guard let image else { return }
            self.image = image
        }
    }

    private var slots: [CGWindowID: Slot]

    init(windowIDs: [CGWindowID]) {
        slots = Dictionary(
            windowIDs.map { ($0, Slot()) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func slot(for windowID: CGWindowID) -> Slot {
        if let slot = slots[windowID] { return slot }
        let slot = Slot()
        slots[windowID] = slot
        return slot
    }

    func update(_ image: CGImage?, for windowID: CGWindowID) {
        slot(for: windowID).update(image)
    }
}

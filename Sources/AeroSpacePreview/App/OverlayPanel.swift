import AppKit

/// Borderless panels refuse key status by default; the overlay needs it for
/// Esc and keyboard navigation.
final class OverlayPanel: NSPanel {
    var onCancel: (@MainActor () -> Void)?
    var onKey: (@MainActor (NSEvent) -> Bool)?
    var acceptsInput = true

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        guard acceptsInput else { return }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        guard acceptsInput else { return }
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        guard acceptsInput else { return }
        if onKey?(event) != true {
            super.keyDown(with: event) // lets Esc reach cancelOperation
        }
    }
}

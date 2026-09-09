import AppKit
import CoreGraphics
import SwiftUI

/// Owns AppKit presentation and releases per-summon view state when cleared.
@MainActor
final class OverlayPanelPresenter: NSObject, OverlayPresenting, NSWindowDelegate {
    private var panel: OverlayPanel?
    private var onDismiss: (@MainActor () -> Void)?
    private var presentationID: UInt64 = 0

    var isVisible: Bool { panel?.isVisible ?? false }

    func targetDisplay() -> OverlayDisplayTarget? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        return OverlayDisplayTarget(displayID: Self.displayID(for: screen))
    }

    func present(
        _ viewModel: OverlayViewModel,
        on target: OverlayDisplayTarget,
        onDismiss: @escaping @MainActor () -> Void
    ) -> Bool {
        let screen = target.displayID.flatMap { wanted in
            NSScreen.screens.first(where: { Self.displayID(for: $0) == wanted })
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return false }

        let panel = self.panel ?? makePanel()
        panel.setFrame(screen.frame, display: true)
        installContent(viewModel, in: panel, onDismiss: onDismiss)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        return true
    }

    /// Installing content separately lets adapter tests exercise actual AppKit
    /// retention and teardown without ordering a full-screen panel forward.
    func installContent(
        _ viewModel: OverlayViewModel,
        in panel: OverlayPanel,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        if let previousPanel = self.panel, previousPanel !== panel {
            clear()
        }
        self.panel = panel
        self.onDismiss = onDismiss
        presentationID &+= 1
        let presentationID = presentationID
        panel.delegate = self
        panel.acceptsInput = true
        panel.ignoresMouseEvents = false
        panel.onCancel = { [weak self] in
            self?.requestDismissal(for: presentationID)
        }
        panel.onKey = { [viewModel] event in viewModel.handle(event) }
        panel.contentView = NSHostingView(rootView: OverlayRootView(viewModel: viewModel))
    }

    func dismiss(completion: @escaping @MainActor () -> Void) {
        disableInput()
        guard let panel else {
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                completion()
            }
        })
    }

    func clear() {
        disableInput()
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let eventPanel = notification.object as? OverlayPanel,
              eventPanel === panel
        else { return }
        requestDismissal(for: presentationID)
    }

    private func requestDismissal(for presentationID: UInt64) {
        guard self.presentationID == presentationID,
              panel?.acceptsInput == true
        else { return }
        onDismiss?()
    }

    private func disableInput() {
        onDismiss = nil
        panel?.delegate = nil
        panel?.onCancel = nil
        panel?.onKey = nil
        panel?.acceptsInput = false
        panel?.ignoresMouseEvents = true
    }

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

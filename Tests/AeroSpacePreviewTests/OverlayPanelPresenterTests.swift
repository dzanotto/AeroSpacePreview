import AppKit
import Testing
@testable import AeroSpacePreview

@MainActor
@Suite struct OverlayPanelPresenterTests {
    @Test func clearingHiddenPanelReleasesViewModelAndCallbacks() {
        let presenter = OverlayPanelPresenter()
        let panel = makePanel()
        weak var retainedViewModel: OverlayViewModel?
        var dismissCount = 0
        autoreleasepool {
            let viewModel = makeViewModel()
            retainedViewModel = viewModel
            presenter.installContent(viewModel, in: panel) { dismissCount += 1 }

            #expect(panel.contentView != nil)
            #expect(panel.onKey != nil)
            #expect(!presenter.isVisible)
            panel.cancelOperation(nil)
            #expect(dismissCount == 1)

            presenter.clear()
            presenter.clear()
        }

        // AppKit may autorelease the detached hosting view until the current
        // event's pool drains, even though the presenter has released it.
        #expect(retainedViewModel == nil)
        #expect(panel.contentView == nil)
        #expect(panel.onKey == nil)
        #expect(panel.onCancel == nil)
        #expect(panel.delegate == nil)
        #expect(!panel.acceptsInput)
        #expect(panel.ignoresMouseEvents)
        panel.cancelOperation(nil)
        #expect(dismissCount == 1)
    }

    @Test func dismissalDisablesInputBeforeCompletionAndKeepsContentUntilClear() async {
        let presenter = OverlayPanelPresenter()
        let panel = makePanel()
        var dismissCount = 0
        presenter.installContent(makeViewModel(), in: panel) { dismissCount += 1 }

        await withCheckedContinuation { continuation in
            presenter.dismiss { continuation.resume() }
            #expect(panel.onKey == nil)
            #expect(panel.onCancel == nil)
            #expect(panel.delegate == nil)
            #expect(!panel.acceptsInput)
            #expect(panel.ignoresMouseEvents)
            panel.cancelOperation(nil)
            presenter.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
            #expect(dismissCount == 0)
        }

        #expect(panel.contentView != nil)
        presenter.clear()
        #expect(panel.contentView == nil)
    }

    @Test func savedCancellationCallbackCannotDismissReplacementContent() {
        let presenter = OverlayPanelPresenter()
        let panel = makePanel()
        var firstDismissCount = 0
        var replacementDismissCount = 0
        presenter.installContent(makeViewModel(), in: panel) { firstDismissCount += 1 }
        let oldCancel = panel.onCancel
        presenter.clear()
        presenter.installContent(makeViewModel(), in: panel) { replacementDismissCount += 1 }

        oldCancel?()
        #expect(firstDismissCount == 0)
        #expect(replacementDismissCount == 0)
        #expect(panel.acceptsInput)
        #expect(!panel.ignoresMouseEvents)

        panel.cancelOperation(nil)
        #expect(replacementDismissCount == 1)
        presenter.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
        #expect(replacementDismissCount == 2)
        presenter.clear()
    }

    private func makePanel() -> OverlayPanel {
        _ = NSApplication.shared
        let panel = OverlayPanel(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func makeViewModel() -> OverlayViewModel {
        OverlayViewModel(
            content: .error("unavailable"),
            actions: OverlayActions(dismiss: {}, selectWorkspace: { _ in }, focusWindow: { _ in })
        )
    }
}

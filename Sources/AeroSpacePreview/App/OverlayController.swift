import AppKit
import CoreGraphics
import SwiftUI

/// Owns the full-screen overlay panel and the per-summon snapshot lifecycle:
/// summon → fetch AeroSpace state + capture thumbnails → present → act/dismiss.
@MainActor
final class OverlayController: NSObject, NSWindowDelegate {
    private var panel: OverlayPanel?
    private var isLoading = false
    private var isHiding = false
    private var client: AeroSpaceClient?
    private let capture = CaptureService()

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        guard !isVisible, !isLoading else { return }
        isLoading = true
        if client == nil { client = try? AeroSpaceClient.discover() }

        Task { [client, capture] in
            let content = await Self.loadContent(client: client, capture: capture)
            self.present(content)
            self.isLoading = false
        }
    }

    func hide() {
        guard let panel, isVisible, !isHiding else { return }
        isHiding = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                self.isHiding = false
            }
        })
    }

    // MARK: - Snapshot assembly (off the main actor; CLI calls block briefly)

    private nonisolated static func loadContent(
        client: AeroSpaceClient?,
        capture: CaptureService
    ) async -> OverlayContent {
        guard let client else {
            return .error("aerospace CLI not found.\nIs AeroSpace installed? (brew install --cask nikitabobko/tap/aerospace)")
        }
        do {
            let snapshot = try client.fetchSnapshot()
            let permissionDenied = !ScreenRecordingPermission.isGranted
            let thumbnails = permissionDenied
                ? [:]
                : await capture.thumbnails(for: snapshot.allWindows.map(\.id), maxPixel: 640)
            return .snapshot(OverlaySnapshot(
                workspaces: snapshot.workspaces,
                thumbnails: thumbnails,
                permissionDenied: permissionDenied
            ))
        } catch {
            return .error(String(describing: error))
        }
    }

    // MARK: - Presentation

    private func present(_ content: OverlayContent) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let actions = OverlayActions(
            dismiss: { [weak self] in self?.hide() },
            selectWorkspace: { [weak self] name in self?.perform { try $0.switchToWorkspace(name) } },
            focusWindow: { [weak self] id in self?.perform { try $0.focusWindow(id: id) } }
        )

        let viewModel = OverlayViewModel(content: content, actions: actions)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(screen.frame, display: true)
        panel.onKey = { [viewModel] event in viewModel.handle(event) }
        panel.contentView = NSHostingView(rootView: OverlayRootView(viewModel: viewModel))
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    /// Runs an aerospace action off the main actor and dismisses immediately —
    /// the workspace switch itself is the visual feedback.
    private func perform(_ action: @escaping @Sendable (AeroSpaceClient) throws -> Void) {
        hide()
        guard let client else { return }
        Task.detached(priority: .userInitiated) {
            do {
                try action(client)
            } catch {
                NSLog("AeroSpacePreview: action failed: \(error)")
            }
        }
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
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide() }
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}

/// Borderless panels refuse key status by default; the overlay needs it for
/// Esc and keyboard navigation.
final class OverlayPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true {
            super.keyDown(with: event) // lets Esc reach cancelOperation
        }
    }
}

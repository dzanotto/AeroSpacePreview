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
    private let frameCache = FrameCacheStore()
    private var harvestTask: Task<Void, Never>?
    /// Covers both the progressive one-shot pass and the live-stream phase.
    /// Dismissal cancels it, which terminates and stops every SCStream.
    private var captureTask: Task<Void, Never>?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        guard !isVisible, !isLoading else { return }
        isLoading = true
        captureTask?.cancel()
        if client == nil { client = try? AeroSpaceClient.discover() }

        // Present as soon as AeroSpace state is in (a few CLI round-trips);
        // captures start at the same moment and stream in one by one
        // (~30 ms/window, serialized by SCK — see M6 measurements in
        // PLAN.md). Placeholders cover whatever hasn't landed yet.
        captureTask = Task { [client, capture] in
            let clock = ContinuousClock()
            let start = clock.now
            let content = await Self.loadState(client: client)

            var stream: AsyncStream<CaptureEvent>?
            var windowCount = 0
            if case .snapshot(let snapshot) = content, !snapshot.permissionDenied {
                let windowIDs = snapshot.allWindowIDs
                windowCount = windowIDs.count
                stream = capture.captureStream(for: windowIDs, maxPixel: 640)
            }
            let stateDone = clock.now

            let viewModel = self.present(content)
            self.isLoading = false

            guard let stream, let viewModel else { return }
            var captured = 0
            for await event in stream {
                guard !Task.isCancelled else { return }
                switch event {
                case .frames(let harvest):
                    // The focused workspace is on screen right now, so its
                    // frames are real — cache them and upgrade its tile.
                    guard case .snapshot(let snapshot) = content,
                          let focused = snapshot.focusedWorkspace else { break }
                    self.frameCache.store(
                        workspace: focused.name,
                        windowIDs: focused.windows.map(\.id),
                        harvest: harvest
                    )
                    if let layout = self.frameCache.layout(for: focused) {
                        viewModel.layouts[focused.name] = layout
                    }
                case .thumbnail(let id, let image):
                    viewModel.thumbnails.update(image, for: id)
                    captured += 1
                }
            }
            NSLog(
                "AeroSpacePreview: summon — state %.0f ms, capture %.0f ms (%ld/%ld windows)",
                start.duration(to: stateDone) / .milliseconds(1),
                stateDone.duration(to: clock.now) / .milliseconds(1),
                captured, windowCount
            )

            // The one-shot pass supplies immediate stills and remains the
            // fallback for any stream that cannot start. Live streams publish
            // only changed frames; idle windows keep that still image.
            guard !Task.isCancelled, self.isVisible,
                  case .snapshot(let snapshot) = content,
                  !snapshot.permissionDenied,
                  !snapshot.allWindowIDs.isEmpty
            else { return }
            let liveStream = capture.liveThumbnailStream(
                for: snapshot.allWindowIDs,
                maxPixel: 640,
                framesPerSecond: 30
            )
            for await frame in liveStream {
                guard !Task.isCancelled, self.isVisible else { return }
                viewModel.thumbnails.update(frame.image, for: frame.windowID)
            }
        }
    }

    func hide() {
        guard let panel, isVisible, !isHiding else { return }
        captureTask?.cancel()
        captureTask = nil
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

    // MARK: - State assembly (off the main actor; CLI calls block briefly)

    private nonisolated static func loadState(client: AeroSpaceClient?) async -> OverlayContent {
        guard let client else {
            return .error("aerospace CLI not found.\nIs AeroSpace installed? (brew install --cask nikitabobko/tap/aerospace)")
        }
        do {
            let snapshot = try await client.fetchSnapshot()
            return .snapshot(OverlaySnapshot(
                workspaces: snapshot.workspaces,
                permissionDenied: !ScreenRecordingPermission.isGranted
            ))
        } catch {
            return .error(String(describing: error))
        }
    }

    // MARK: - Presentation

    @discardableResult
    private func present(_ content: OverlayContent) -> OverlayViewModel? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }

        let actions = OverlayActions(
            dismiss: { [weak self] in self?.hide() },
            selectWorkspace: { [weak self] name in self?.perform { try $0.switchToWorkspace(name) } },
            focusWindow: { [weak self] id in self?.perform { try $0.focusWindow(id: id) } }
        )

        let viewModel = OverlayViewModel(content: content, actions: actions)
        if case .snapshot(let snapshot) = content {
            for workspace in snapshot.workspaces {
                if let layout = frameCache.layout(for: workspace) {
                    viewModel.layouts[workspace.name] = layout
                }
            }
        }
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
        return viewModel
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
                return
            }
            await self.scheduleFocusedWorkspaceHarvest()
        }
    }

    /// An overlay action just revealed a workspace — once it settles, snapshot
    /// its real window frames into the layout cache in the background. Normal
    /// use of the app populates the cache by itself this way.
    private func scheduleFocusedWorkspaceHarvest() {
        guard let client, ScreenRecordingPermission.isGranted else { return }
        harvestTask?.cancel()
        harvestTask = Task { [capture, frameCache] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled,
                  let focused = try? await client.fetchFocusedWorkspaceWindows(),
                  !focused.windowIDs.isEmpty,
                  let harvest = await capture.windowFrames(for: focused.windowIDs),
                  !Task.isCancelled
            else { return }
            frameCache.store(
                workspace: focused.workspace,
                windowIDs: focused.windowIDs,
                harvest: harvest
            )
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

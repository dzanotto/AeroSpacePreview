import AppKit
import CoreGraphics
import SwiftUI

/// Owns the full-screen overlay panel and the per-summon snapshot lifecycle:
/// summon → fetch AeroSpace state → present → publish captures → act/dismiss.
@MainActor
final class OverlayController: NSObject, NSWindowDelegate {
    private var panel: OverlayPanel?
    private let lifetime = OverlayLifetime()
    private var client: AeroSpaceClient?
    private let oneShotCapture = OneShotCaptureService()
    private let liveThumbnails = LiveThumbnailCoordinator()
    private let frameCache = FrameCacheStore()
    private let diagnostics = CaptureDiagnostics()
    private let resourceSampler = ProcessResourceSampler()
    /// Last rendered wallpaper frame per display, retained to avoid showing
    /// the windows behind the panel while a new per-summon capture arrives.
    private var desktopBackgrounds: [CGDirectDisplayID: CGImage] = [:]
    private var diagnosticsEnabled: Bool
    private weak var currentViewModel: OverlayViewModel?

    var isVisible: Bool { panel?.isVisible ?? false }
    var isDiagnosticsEnabled: Bool { diagnosticsEnabled }

    init(diagnosticsEnabled: Bool = false) {
        self.diagnosticsEnabled = diagnosticsEnabled
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func toggleDiagnostics() {
        setDiagnosticsEnabled(!diagnosticsEnabled)
    }

    func setDiagnosticsEnabled(_ enabled: Bool) {
        guard enabled != diagnosticsEnabled else { return }
        diagnosticsEnabled = enabled
        guard let sessionID = lifetime.currentSessionID,
              lifetime.isCurrent(sessionID, phase: .visible),
              let currentViewModel
        else { return }
        if enabled {
            startDiagnosticsSession(viewModel: currentViewModel, sessionID: sessionID)
        } else {
            stopDiagnosticsSession(sessionID: sessionID, logSummary: true)
        }
    }

    func show() {
        guard !isVisible else { return }
        guard let targetScreen = NSScreen.main ?? NSScreen.screens.first else { return }
        guard let sessionID = lifetime.beginLoading() else { return }
        let targetDisplayID = Self.displayID(for: targetScreen)
        if client == nil { client = try? AeroSpaceClient.discover() }

        // Present as soon as AeroSpace state is in (a few CLI round-trips);
        // captures start at the same moment and stream in one by one.
        // ScreenCaptureKit serializes much of this work, so placeholders
        // cover whatever has not arrived yet.
        let captureTask = Task { [client, oneShotCapture, liveThumbnails] in
            let clock = ContinuousClock()
            let start = clock.now
            let content = await Self.loadState(client: client)
            guard !Task.isCancelled,
                  self.lifetime.isCurrent(sessionID, phase: .loading)
            else { return }

            var stream: AsyncStream<CaptureEvent>?
            var windowCount = 0
            if case .snapshot(let snapshot) = content, !snapshot.permissionDenied {
                let windowIDs = snapshot.allWindowIDs
                windowCount = windowIDs.count
                stream = oneShotCapture.captureStream(
                    for: windowIDs,
                    maxPixel: 320,
                    desktopDisplayID: targetDisplayID
                )
            }
            self.diagnostics.prepareSummon(
                windowIDs: stream == nil ? [] : content.windowIDsForDiagnostics
            )
            let stateDone = clock.now

            guard let viewModel = self.present(content, displayID: targetDisplayID) else {
                self.lifetime.abort(sessionID)
                return
            }
            guard self.lifetime.markVisible(sessionID) else { return }
            if self.diagnosticsEnabled {
                self.startDiagnosticsSession(viewModel: viewModel, sessionID: sessionID)
            }

            guard let stream else { return }
            guard let captured = await self.consumeOneShotEvents(
                stream,
                content: content,
                targetDisplayID: targetDisplayID,
                viewModel: viewModel,
                sessionID: sessionID
            ) else { return }
            NSLog(
                "AeroSpacePreview: summon — state %.0f ms, capture %.0f ms (%ld/%ld windows)",
                start.duration(to: stateDone) / .milliseconds(1),
                stateDone.duration(to: clock.now) / .milliseconds(1),
                captured, windowCount
            )

            // The one-shot pass supplies immediate stills and remains the
            // fallback for any stream that cannot start. Live streams publish
            // only changed frames; idle windows keep that still image.
            guard !Task.isCancelled,
                  self.lifetime.isCurrent(sessionID, phase: .visible),
                  case .snapshot(let snapshot) = content,
                  !snapshot.permissionDenied,
                  !snapshot.allWindowIDs.isEmpty
            else { return }
            let liveCapture = liveThumbnails.start(
                for: snapshot.allWindowIDs,
                maxPixel: 320,
                framesPerSecond: 30,
                diagnostics: self.diagnostics
            )
            guard self.lifetime.installLiveCapture(liveCapture, for: sessionID) else { return }
            defer {
                liveCapture.stop()
                self.lifetime.releaseLiveCapture(liveCapture, for: sessionID)
            }
            await self.consumeLiveFrames(
                liveCapture.frames,
                viewModel: viewModel,
                sessionID: sessionID
            )
        }
        lifetime.installCaptureTask(captureTask, for: sessionID)
    }

    private func consumeOneShotEvents(
        _ stream: AsyncStream<CaptureEvent>,
        content: OverlayContent,
        targetDisplayID: CGDirectDisplayID?,
        viewModel: OverlayViewModel,
        sessionID: OverlayLifetime.SessionID
    ) async -> Int? {
        var captured = 0
        for await event in stream {
            guard !Task.isCancelled,
                  lifetime.isCurrent(sessionID, phase: .visible)
            else { return nil }
            switch event {
            case .frames(let harvest):
                // The focused workspace is on screen right now, so its frames
                // are real — cache them and upgrade its tile.
                guard case .snapshot(let snapshot) = content,
                      let focused = snapshot.focusedWorkspace else { break }
                frameCache.store(
                    workspace: focused.name,
                    windowIDs: focused.windows.map(\.id),
                    harvest: harvest
                )
                if let layout = frameCache.layout(for: focused) {
                    viewModel.layouts[focused.name] = layout
                }
            case .desktopBackground(let image):
                if let targetDisplayID {
                    desktopBackgrounds[targetDisplayID] = image
                }
                viewModel.publishDesktopBackground(image)
            case .thumbnail(let id, let image):
                viewModel.thumbnails.update(image, for: id)
                captured += 1
            }
        }
        return captured
    }

    private func consumeLiveFrames(
        _ frames: AsyncStream<LiveThumbnailFrame>,
        viewModel: OverlayViewModel,
        sessionID: OverlayLifetime.SessionID
    ) async {
        for await frame in frames {
            guard !Task.isCancelled,
                  lifetime.isCurrent(sessionID, phase: .visible)
            else { return }
            viewModel.thumbnails.update(frame.image, for: frame.windowID)
            diagnostics.recordUIDelivery(timing: frame.diagnosticsTiming)
        }
    }

    func hide() {
        guard let panel, isVisible else { return }
        guard let sessionID = lifetime.beginHiding() else { return }
        stopDiagnosticsSession(sessionID: sessionID, logSummary: true)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard self.lifetime.finishHiding(sessionID) else { return }
                panel.orderOut(nil)
                self.currentViewModel = nil
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
    private func present(
        _ content: OverlayContent,
        displayID: CGDirectDisplayID?
    ) -> OverlayViewModel? {
        let screen = displayID.flatMap { wanted in
            NSScreen.screens.first(where: { Self.displayID(for: $0) == wanted })
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return nil }

        let actions = OverlayActions(
            dismiss: { [weak self] in self?.hide() },
            selectWorkspace: { [weak self] name in self?.perform { try await $0.switchToWorkspace(name) } },
            focusWindow: { [weak self] id in self?.perform { try await $0.focusWindow(id: id) } }
        )

        let viewModel = OverlayViewModel(
            content: content,
            actions: actions,
            desktopBackground: displayID.flatMap { desktopBackgrounds[$0] }
        )
        currentViewModel = viewModel
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

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    // MARK: - Diagnostics

    private func startDiagnosticsSession(
        viewModel: OverlayViewModel,
        sessionID: OverlayLifetime.SessionID
    ) {
        guard diagnosticsEnabled,
              lifetime.isCurrent(sessionID, phase: .visible),
              !diagnostics.isEnabled
        else { return }
        lifetime.stopDiagnostics(for: sessionID)
        let labels = viewModel.content.windowLabelsForDiagnostics
        diagnostics.beginSession(windowLabels: labels)

        let diagnostics = self.diagnostics
        let sampler = resourceSampler
        let diagnosticsTask = Task.detached(priority: .utility) { [weak self, weak viewModel] in
            var baseline = sampler.sample()
            var previous = baseline

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }

                if let current = sampler.sample() {
                    if baseline == nil { baseline = current }
                    if previous == nil { previous = current }
                    if let previous,
                       let baseline,
                       let currentDelta = ProcessResourceMath.delta(from: previous, to: current),
                       let sessionDelta = ProcessResourceMath.delta(from: baseline, to: current) {
                        diagnostics.recordProcessResources(
                            currentCPUPercentage: currentDelta.cpuPercentage,
                            averageCPUPercentage: sessionDelta.cpuPercentage,
                            physicalFootprintBytes: current.physicalFootprintBytes,
                            packageIdleWakeupsPerSecond: currentDelta.packageIdleWakeupsPerSecond
                        )
                    }
                    previous = current
                }

                guard let snapshot = diagnostics.makeSnapshot() else { return }
                await MainActor.run { [weak self, weak viewModel] in
                    guard self?.lifetime.isCurrent(sessionID, phase: .visible) == true else {
                        return
                    }
                    viewModel?.publishDiagnostics(snapshot)
                }
            }
        }
        lifetime.installDiagnosticsTask(diagnosticsTask, for: sessionID)
    }

    private func stopDiagnosticsSession(
        sessionID: OverlayLifetime.SessionID,
        logSummary: Bool
    ) {
        lifetime.stopDiagnostics(for: sessionID)
        currentViewModel?.publishDiagnostics(nil)
        guard let snapshot = diagnostics.endSession() else { return }
        if logSummary {
            NSLog("%@", DiagnosticsHUDFormatter.dismissalSummary(snapshot))
        }
    }

    func shutdown() {
        if let sessionID = lifetime.currentSessionID {
            stopDiagnosticsSession(sessionID: sessionID, logSummary: true)
        }
        lifetime.shutdown()
        currentViewModel = nil
    }

    /// Runs an aerospace action off the main actor and dismisses immediately —
    /// the workspace switch itself is the visual feedback.
    private func perform(_ action: @escaping @Sendable (AeroSpaceClient) async throws -> Void) {
        hide()
        guard let client else { return }
        let postActionTask = Task(priority: .userInitiated) { [oneShotCapture, frameCache] in
            do {
                try await action(client)
            } catch is CancellationError {
                return
            } catch {
                NSLog("AeroSpacePreview: action failed: \(error)")
                return
            }
            guard !Task.isCancelled, ScreenRecordingPermission.isGranted else { return }
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let focused = try? await client.fetchFocusedWorkspaceWindows(),
                  !focused.windowIDs.isEmpty,
                  let harvest = await oneShotCapture.windowFrames(for: focused.windowIDs),
                  !Task.isCancelled
            else { return }
            frameCache.store(
                workspace: focused.workspace,
                windowIDs: focused.windowIDs,
                harvest: harvest
            )
        }
        lifetime.replacePostActionTask(postActionTask)
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

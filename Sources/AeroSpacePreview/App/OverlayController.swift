import CoreGraphics
import Foundation

/// Coordinates presentation and the per-summon snapshot lifecycle:
/// summon → fetch AeroSpace state → present → publish captures → act/dismiss.
@MainActor
final class OverlayController {
    typealias ContentLoader = @Sendable (AeroSpaceClient?, Bool) async -> OverlayContent

    private let presenter: any OverlayPresenting
    private let lifetime = OverlayLifetime()
    private var client: AeroSpaceClient?
    private let discoverClient: @MainActor () -> AeroSpaceClient?
    private let loadContent: ContentLoader
    private let oneShotCapture: OneShotCaptureService
    private let liveThumbnails: LiveThumbnailCoordinator
    private let frameCache = FrameCacheStore()
    private let diagnostics = CaptureDiagnostics()
    private let resourceSampler = ProcessResourceSampler()
    /// Last rendered wallpaper frame per display, retained to avoid showing
    /// the windows behind the panel while a new per-summon capture arrives.
    private var desktopBackgrounds: [CGDirectDisplayID: CGImage] = [:]
    private var diagnosticsEnabled: Bool
    private var currentViewModel: OverlayViewModel?
    private var showEmptyWorkspaces: Bool

    var isVisible: Bool { presenter.isVisible }
    var isDiagnosticsEnabled: Bool { diagnosticsEnabled }
    var isShowingEmptyWorkspaces: Bool { showEmptyWorkspaces }

    init(
        diagnosticsEnabled: Bool = false,
        showEmptyWorkspaces: Bool = false,
        presenter: any OverlayPresenting = OverlayPanelPresenter(),
        oneShotCapture: OneShotCaptureService = OneShotCaptureService(),
        liveThumbnails: LiveThumbnailCoordinator = LiveThumbnailCoordinator(),
        discoverClient: @escaping @MainActor () -> AeroSpaceClient? = { try? AeroSpaceClient.discover() },
        loadContent: @escaping ContentLoader = OverlayController.loadState
    ) {
        self.diagnosticsEnabled = diagnosticsEnabled
        self.showEmptyWorkspaces = showEmptyWorkspaces
        self.presenter = presenter
        self.oneShotCapture = oneShotCapture
        self.liveThumbnails = liveThumbnails
        self.discoverClient = discoverClient
        self.loadContent = loadContent
    }

    func toggle() {
        switch lifetime.phase {
        case .idle: show()
        case .loading, .visible: hide()
        case .hiding: break
        }
    }

    func toggleDiagnostics() {
        setDiagnosticsEnabled(!diagnosticsEnabled)
    }

    func toggleShowEmptyWorkspaces() {
        showEmptyWorkspaces.toggle()
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
        guard let sessionID = lifetime.beginLoading() else { return }
        guard let target = presenter.targetDisplay() else {
            lifetime.abort(sessionID)
            return
        }
        let targetDisplayID = target.displayID
        let showEmptyWorkspaces = showEmptyWorkspaces
        if client == nil { client = discoverClient() }

        // Present as soon as AeroSpace state is in (a few CLI round-trips);
        // captures start at the same moment and stream in one by one.
        // ScreenCaptureKit serializes much of this work, so placeholders
        // cover whatever has not arrived yet.
        let captureTask = Task { [client, loadContent, oneShotCapture, liveThumbnails] in
            let clock = ContinuousClock()
            let start = clock.now
            let content = await loadContent(client, showEmptyWorkspaces)
            guard !Task.isCancelled,
                  self.lifetime.isCurrent(sessionID, phase: .loading)
            else { return }

            let stateDone = clock.now
            let viewModel = self.makeViewModel(content, displayID: targetDisplayID, sessionID: sessionID)
            guard self.presenter.present(viewModel, on: target, onDismiss: { [weak self] in
                guard self?.lifetime.isCurrent(sessionID, phase: .visible) == true else { return }
                self?.hide()
            }) else {
                self.presenter.clear()
                self.lifetime.abort(sessionID)
                return
            }
            guard self.lifetime.markVisible(sessionID) else {
                self.presenter.clear()
                return
            }
            self.currentViewModel = viewModel
            let captureSnapshot: OverlaySnapshot?
            if case .snapshot(let snapshot) = content, !snapshot.permissionDenied {
                captureSnapshot = snapshot
            } else {
                captureSnapshot = nil
            }
            self.diagnostics.prepareSummon(windowIDs: captureSnapshot?.allWindowIDs ?? [])
            if self.diagnosticsEnabled {
                self.startDiagnosticsSession(viewModel: viewModel, sessionID: sessionID)
            }

            // An eager capture producer must have a successfully presented
            // session and a consumer that owns its cancellation.
            guard let captureSnapshot else { return }
            let windowCount = captureSnapshot.allWindowIDs.count
            let stream = oneShotCapture.captureStream(
                for: captureSnapshot.allWindowIDs,
                maxPixel: 320,
                desktopDisplayID: targetDisplayID
            )
            guard let captured = await OverlayCaptureConsumer.consumeOneShotEvents(
                stream,
                content: content,
                targetDisplayID: targetDisplayID,
                viewModel: viewModel,
                frameCache: self.frameCache,
                isCurrent: {
                    self.lifetime.isCurrent(sessionID, phase: .visible)
                },
                cacheDesktopBackground: { displayID, image in
                    self.desktopBackgrounds[displayID] = image
                }
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
            await OverlayCaptureConsumer.consumeLiveFrames(
                liveCapture.frames,
                viewModel: viewModel,
                diagnostics: self.diagnostics,
                isCurrent: {
                    self.lifetime.isCurrent(sessionID, phase: .visible)
                }
            )
        }
        lifetime.installCaptureTask(captureTask, for: sessionID)
    }

    func hide() {
        if lifetime.phase == .loading, let sessionID = lifetime.currentSessionID {
            lifetime.abort(sessionID)
            return
        }
        guard let sessionID = lifetime.beginHiding() else { return }
        stopDiagnosticsSession(sessionID: sessionID, logSummary: true)
        presenter.dismiss { [weak self] in
            guard let self, self.lifetime.finishHiding(sessionID) else { return }
            self.presenter.clear()
            self.currentViewModel = nil
        }
    }

    // MARK: - State assembly

    nonisolated static func loadState(
        _ client: AeroSpaceClient?,
        _ showEmptyWorkspaces: Bool
    ) async -> OverlayContent {
        guard let client else {
            return .error("aerospace CLI not found.\nIs AeroSpace installed? (brew install --cask nikitabobko/tap/aerospace)")
        }
        do {
            let snapshot = try await client.fetchSnapshot(
                includeEmptyWorkspaces: showEmptyWorkspaces
            )
            return .snapshot(OverlaySnapshot(
                workspaces: snapshot.workspaces,
                permissionDenied: !ScreenRecordingPermission.isGranted
            ))
        } catch {
            return .error(String(describing: error))
        }
    }

    // MARK: - Presentation

    private func makeViewModel(
        _ content: OverlayContent,
        displayID: CGDirectDisplayID?,
        sessionID: OverlayLifetime.SessionID
    ) -> OverlayViewModel {
        let actions = OverlayActions(
            dismiss: { [weak self] in
                guard self?.lifetime.isCurrent(sessionID, phase: .visible) == true else { return }
                self?.hide()
            },
            selectWorkspace: { [weak self] name in
                guard self?.lifetime.isCurrent(sessionID, phase: .visible) == true else { return }
                self?.perform { try await $0.switchToWorkspace(name) }
            },
            focusWindow: { [weak self] id in
                guard self?.lifetime.isCurrent(sessionID, phase: .visible) == true else { return }
                self?.perform { try await $0.focusWindow(id: id) }
            }
        )

        let viewModel = OverlayViewModel(
            content: content,
            actions: actions,
            desktopBackground: displayID.flatMap { desktopBackgrounds[$0] }
        )
        if case .snapshot(let snapshot) = content {
            for workspace in snapshot.workspaces {
                if let layout = frameCache.layout(for: workspace) {
                    viewModel.layouts[workspace.name] = layout
                }
            }
        }
        return viewModel
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
        presenter.clear()
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

}

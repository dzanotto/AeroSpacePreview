import Foundation

/// Testable lifecycle and asynchronous-work ownership for the one overlay
/// summon that may be active at a time. Session IDs keep late callbacks from
/// an ended summon from mutating a newer one.
@MainActor
final class OverlayLifetime {
    enum Phase: Equatable {
        case idle
        case loading
        case visible
        case hiding
    }

    struct SessionID: Equatable, Hashable, Sendable {
        fileprivate let value: UInt64
    }

    private(set) var phase: Phase = .idle
    private(set) var currentSessionID: SessionID?

    private var nextSessionValue: UInt64 = 0
    private var acceptsNewWork = true
    private var captureTask: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    private var liveCapture: LiveThumbnailCapture?
    private var postActionTask: Task<Void, Never>?

    func beginLoading() -> SessionID? {
        guard acceptsNewWork, phase == .idle else { return nil }
        nextSessionValue &+= 1
        let sessionID = SessionID(value: nextSessionValue)
        currentSessionID = sessionID
        phase = .loading
        return sessionID
    }

    @discardableResult
    func markVisible(_ sessionID: SessionID) -> Bool {
        guard isCurrent(sessionID, phase: .loading) else { return false }
        phase = .visible
        return true
    }

    /// Starts dismissal and immediately stops pixel production. Diagnostics
    /// are stopped by the controller so it can publish and log their summary.
    func beginHiding() -> SessionID? {
        guard phase == .visible, let sessionID = currentSessionID else { return nil }
        phase = .hiding
        stopCapture(for: sessionID)
        return sessionID
    }

    @discardableResult
    func finishHiding(_ sessionID: SessionID) -> Bool {
        guard isCurrent(sessionID, phase: .hiding) else { return false }
        endSession(sessionID)
        return true
    }

    @discardableResult
    func abort(_ sessionID: SessionID) -> Bool {
        guard isCurrent(sessionID) else { return false }
        endSession(sessionID)
        return true
    }

    func isCurrent(_ sessionID: SessionID, phase expectedPhase: Phase? = nil) -> Bool {
        guard acceptsNewWork, currentSessionID == sessionID else { return false }
        return expectedPhase == nil || phase == expectedPhase
    }

    @discardableResult
    func installCaptureTask(_ task: Task<Void, Never>, for sessionID: SessionID) -> Bool {
        guard isCurrent(sessionID, phase: .loading) else {
            task.cancel()
            return false
        }
        captureTask?.cancel()
        captureTask = task
        return true
    }

    @discardableResult
    func installLiveCapture(
        _ capture: LiveThumbnailCapture,
        for sessionID: SessionID
    ) -> Bool {
        guard isCurrent(sessionID, phase: .visible) else {
            capture.stop()
            return false
        }
        liveCapture?.stop()
        liveCapture = capture
        return true
    }

    func releaseLiveCapture(
        _ capture: LiveThumbnailCapture,
        for sessionID: SessionID
    ) {
        guard currentSessionID == sessionID, liveCapture === capture else { return }
        liveCapture = nil
    }

    @discardableResult
    func installDiagnosticsTask(_ task: Task<Void, Never>, for sessionID: SessionID) -> Bool {
        guard isCurrent(sessionID, phase: .visible) else {
            task.cancel()
            return false
        }
        diagnosticsTask?.cancel()
        diagnosticsTask = task
        return true
    }

    func stopDiagnostics(for sessionID: SessionID) {
        guard currentSessionID == sessionID else { return }
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
    }

    /// The action and its layout harvest deliberately outlive normal overlay
    /// dismissal. They remain application-owned and are cancelled only when a
    /// newer action replaces them or when the application shuts down.
    func replacePostActionTask(_ task: Task<Void, Never>) {
        guard acceptsNewWork else {
            task.cancel()
            return
        }
        postActionTask?.cancel()
        postActionTask = task
    }

    func shutdown() {
        acceptsNewWork = false
        if let sessionID = currentSessionID {
            stopCapture(for: sessionID)
            stopDiagnostics(for: sessionID)
        }
        currentSessionID = nil
        phase = .idle
        postActionTask?.cancel()
        postActionTask = nil
    }

    private func stopCapture(for sessionID: SessionID) {
        guard currentSessionID == sessionID else { return }
        liveCapture?.stop()
        liveCapture = nil
        captureTask?.cancel()
        captureTask = nil
    }

    private func endSession(_ sessionID: SessionID) {
        stopCapture(for: sessionID)
        stopDiagnostics(for: sessionID)
        currentSessionID = nil
        phase = .idle
    }
}

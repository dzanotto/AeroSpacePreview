import CoreGraphics

/// Pull-based, per-window latest-frame delivery between conversion queues and
/// the overlay's main-actor consumer.
final class LiveFrameDelivery: @unchecked Sendable {
    private let buffer = LatestByKeyBuffer<CGWindowID, LiveThumbnailFrame>()
    private let diagnostics: CaptureDiagnostics?

    init(diagnostics: CaptureDiagnostics?) {
        self.diagnostics = diagnostics
    }

    func publish(_ frame: LiveThumbnailFrame) {
        _ = buffer.submit(frame, for: frame.windowID) { [diagnostics] replaced in
            diagnostics?.recordYielded(
                timing: frame.diagnosticsTiming,
                replacing: replaced?.diagnosticsTiming
            )
        }
    }

    func next() async -> LiveThumbnailFrame? {
        await buffer.next()
    }

    func finish() {
        for frame in buffer.finish() {
            guard let timing = frame.diagnosticsTiming else { continue }
            diagnostics?.recordYieldRejected(timing: timing, droppedOrCoalesced: false)
        }
    }
}

import os

/// Explicit ownership handle for one group of live ScreenCaptureKit streams.
/// The overlay stops this handle directly on dismissal instead of depending on
/// cancellation of the task consuming `frames` to tear down the producer.
final class LiveThumbnailCapture: @unchecked Sendable {
    typealias NextOperation = @Sendable () async -> LiveThumbnailFrame?
    typealias StopOperation = @Sendable () -> Void

    let frames: AsyncStream<LiveThumbnailFrame>

    private let stopper: LiveThumbnailStopper

    init(
        next: @escaping NextOperation,
        stopOperation: @escaping StopOperation
    ) {
        let stopper = LiveThumbnailStopper(operation: stopOperation)
        self.stopper = stopper
        frames = AsyncStream(
            unfolding: next,
            onCancel: { stopper.stop() }
        )
    }

    /// Idempotent and synchronous from the owner's perspective: future frames
    /// are rejected immediately while asynchronous SCStream shutdown follows.
    func stop() {
        stopper.stop()
    }

    deinit {
        stop()
    }
}

private final class LiveThumbnailStopper: @unchecked Sendable {
    private let lockedOperation: OSAllocatedUnfairLock<LiveThumbnailCapture.StopOperation?>

    init(operation: @escaping LiveThumbnailCapture.StopOperation) {
        lockedOperation = OSAllocatedUnfairLock(initialState: operation)
    }

    func stop() {
        let operation = lockedOperation.withLock { operation in
            defer { operation = nil }
            return operation
        }
        operation?()
    }
}

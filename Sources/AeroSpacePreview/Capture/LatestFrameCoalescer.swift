import os

struct LatestFrameSubmission<Element: Sendable>: Sendable {
    let shouldStartProcessing: Bool
    let replacedElement: Element?
}

/// Lock-backed single-slot mailbox. One element may be processing while the
/// newest submitted element waits; another submission replaces that pending
/// element instead of extending a queue.
final class LatestFrameCoalescer<Element: Sendable>: @unchecked Sendable {
    private struct State: Sendable {
        var pendingElement: Element?
        var isProcessing = false
        var isStopped = false
    }

    private let lockedState = OSAllocatedUnfairLock(initialState: State())

    var isActive: Bool {
        lockedState.withLock { !$0.isStopped }
    }

    func submit(_ element: Element) -> LatestFrameSubmission<Element> {
        lockedState.withLock { state in
            guard !state.isStopped else {
                return LatestFrameSubmission(
                    shouldStartProcessing: false,
                    replacedElement: element
                )
            }

            guard state.isProcessing else {
                state.isProcessing = true
                return LatestFrameSubmission(
                    shouldStartProcessing: true,
                    replacedElement: nil
                )
            }

            let replaced = state.pendingElement
            state.pendingElement = element
            return LatestFrameSubmission(
                shouldStartProcessing: false,
                replacedElement: replaced
            )
        }
    }

    /// Completes the current element and returns the newest pending one. A
    /// non-nil result keeps the processor reservation; nil releases it so the
    /// next submission knows it must start a new drain.
    func next() -> Element? {
        lockedState.withLock { state in
            guard !state.isStopped else {
                state.pendingElement = nil
                state.isProcessing = false
                return nil
            }
            guard let pending = state.pendingElement else {
                state.isProcessing = false
                return nil
            }
            state.pendingElement = nil
            return pending
        }
    }

    /// Rejects future submissions and returns the pending element, if any.
    /// An in-progress operation cannot be interrupted, but its publisher can
    /// use `isActive` to suppress delivery after shutdown.
    func stop() -> Element? {
        lockedState.withLock { state in
            guard !state.isStopped else { return nil }
            state.isStopped = true
            let pending = state.pendingElement
            state.pendingElement = nil
            return pending
        }
    }
}

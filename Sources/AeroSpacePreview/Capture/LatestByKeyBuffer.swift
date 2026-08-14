import os

struct LatestByKeySubmission<Element: Sendable>: Sendable {
    let accepted: Bool
    let replacedElement: Element?
}

/// Lock-backed keyed mailbox for a single asynchronous consumer. Each key has
/// at most one pending element; newer submissions replace that element while
/// retaining the key's delivery order relative to other keys.
final class LatestByKeyBuffer<Key: Hashable & Sendable, Element: Sendable>: @unchecked Sendable {
    private struct State: Sendable {
        var pendingElements: [Key: Element] = [:]
        var pendingKeys: [Key] = []
        var waitingConsumer: CheckedContinuation<Void, Never>?
        var isFinished = false
    }

    private let lockedState = OSAllocatedUnfairLock(initialState: State())

    var pendingCount: Int {
        lockedState.withLock { $0.pendingElements.count }
    }

    /// Submits an element and synchronously reports any element it replaced.
    /// The callback runs before a waiting consumer is resumed, allowing callers
    /// to reserve diagnostics state before delivery can be observed.
    func submit(
        _ element: Element,
        for key: Key,
        onAccepted: @Sendable (Element?) -> Void = { _ in }
    ) -> LatestByKeySubmission<Element> {
        let result: (
            submission: LatestByKeySubmission<Element>,
            waitingConsumer: CheckedContinuation<Void, Never>?
        ) = lockedState.withLock { state in
            guard !state.isFinished else {
                return (
                    LatestByKeySubmission<Element>(
                        accepted: false,
                        replacedElement: nil
                    ),
                    nil
                )
            }

            let replaced = state.pendingElements.updateValue(element, forKey: key)
            if replaced == nil {
                state.pendingKeys.append(key)
            }
            onAccepted(replaced)
            let waitingConsumer = state.waitingConsumer
            state.waitingConsumer = nil
            return (
                LatestByKeySubmission<Element>(
                    accepted: true,
                    replacedElement: replaced
                ),
                waitingConsumer
            )
        }
        result.waitingConsumer?.resume()
        return result.submission
    }

    /// Waits for and removes the next pending element. Only one consumer may
    /// call this method at a time, matching AsyncStream's iterator contract.
    func next() async -> Element? {
        await withCheckedContinuation { continuation in
            let shouldResume = lockedState.withLock { state in
                if state.isFinished || !state.pendingKeys.isEmpty {
                    return true
                } else {
                    precondition(state.waitingConsumer == nil)
                    state.waitingConsumer = continuation
                    return false
                }
            }
            if shouldResume {
                continuation.resume()
            }
        }

        return lockedState.withLock { state in
            guard !state.isFinished, !state.pendingKeys.isEmpty else { return nil }
            let key = state.pendingKeys.removeFirst()
            return state.pendingElements.removeValue(forKey: key)
        }
    }

    /// Rejects future submissions, wakes the consumer, and returns every
    /// pending element so its owner can account for undelivered work.
    func finish() -> [Element] {
        let result: (
            pending: [Element],
            waitingConsumer: CheckedContinuation<Void, Never>?
        ) = lockedState.withLock { state in
            guard !state.isFinished else {
                return ([], nil)
            }
            state.isFinished = true
            let result = state.pendingKeys.compactMap {
                state.pendingElements.removeValue(forKey: $0)
            }
            state.pendingKeys.removeAll(keepingCapacity: false)
            let waitingConsumer = state.waitingConsumer
            state.waitingConsumer = nil
            return (result, waitingConsumer)
        }
        result.waitingConsumer?.resume()
        return result.pending
    }
}

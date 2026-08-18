import os
import Testing
@testable import AeroSpacePreview

@Suite struct BoundedAsyncBatchTests {
    @Test func capsConcurrencyAndStartsQueuedWorkAsJobsFinish() async {
        let gate = BatchGate()
        let results = LockedBatchResults()
        let batch = BoundedAsyncBatch(
            elements: Array(1...5),
            maximumConcurrentTasks: 2,
            operation: { value in
                await gate.enterAndWait()
                return value
            }
        )
        let task = Task {
            await batch.run { results.append($0) }
        }

        await gate.waitUntilStarted(2)
        var snapshot = await gate.snapshot
        #expect(snapshot.started == 2)
        #expect(snapshot.active == 2)
        #expect(snapshot.maximumActive == 2)

        await gate.release(1)
        await gate.waitUntilStarted(3)
        snapshot = await gate.snapshot
        #expect(snapshot.active == 2)
        #expect(snapshot.maximumActive == 2)

        await gate.release(4)
        await task.value
        snapshot = await gate.snapshot
        #expect(snapshot.started == 5)
        #expect(snapshot.active == 0)
        #expect(snapshot.maximumActive == 2)
        #expect(Set(results.values) == Set(1...5))
    }

    @Test func cancellationPreventsQueuedWorkFromStarting() async {
        let gate = BatchGate()
        let results = LockedBatchResults()
        let batch = BoundedAsyncBatch(
            elements: Array(1...3),
            maximumConcurrentTasks: 1,
            operation: { value in
                await gate.enterAndWait()
                return value
            }
        )
        let task = Task {
            await batch.run { results.append($0) }
        }

        await gate.waitUntilStarted(1)
        task.cancel()
        await gate.release(1)
        await task.value

        let snapshot = await gate.snapshot
        #expect(snapshot.started == 1)
        #expect(snapshot.active == 0)
        #expect(results.values.isEmpty)
    }
}

private actor BatchGate {
    struct Snapshot: Sendable {
        let started: Int
        let active: Int
        let maximumActive: Int
    }

    private var started = 0
    private var active = 0
    private var maximumActive = 0
    private var permits = 0
    private var permitWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var snapshot: Snapshot {
        Snapshot(started: started, active: active, maximumActive: maximumActive)
    }

    func enterAndWait() async {
        started += 1
        active += 1
        maximumActive = max(maximumActive, active)
        resumeSatisfiedStartWaiters()

        if permits > 0 {
            permits -= 1
        } else {
            await withCheckedContinuation { continuation in
                permitWaiters.append(continuation)
            }
        }
        active -= 1
    }

    func waitUntilStarted(_ count: Int) async {
        guard started < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func release(_ count: Int) {
        for _ in 0..<count {
            if permitWaiters.isEmpty {
                permits += 1
            } else {
                permitWaiters.removeFirst().resume()
            }
        }
    }

    private func resumeSatisfiedStartWaiters() {
        let ready = startWaiters.filter { started >= $0.count }
        startWaiters.removeAll { started >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

private final class LockedBatchResults: @unchecked Sendable {
    private let lockedValues = OSAllocatedUnfairLock(initialState: [Int]())

    var values: [Int] {
        lockedValues.withLock { $0 }
    }

    func append(_ value: Int) {
        lockedValues.withLock { $0.append(value) }
    }
}

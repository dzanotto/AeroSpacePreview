import CoreGraphics
import os
import Testing
@testable import AeroSpacePreview

@Suite struct OneShotCaptureBatchTests {
    @Test func publishesGeometryFirstAndOmitsFailedCaptureJobs() async throws {
        let gate = CaptureJobGate()
        let events = CaptureEventLog()
        let smallImage = try #require(PlaceholderRenderer.render(
            bundleID: "com.does.not.exist",
            size: CGSize(width: 8, height: 8)
        ))
        let largeImage = try #require(PlaceholderRenderer.render(
            bundleID: "com.does.not.exist",
            size: CGSize(width: 16, height: 10)
        ))
        let batch = OneShotCaptureBatch(
            frames: WindowFrameHarvest(
                frames: [101: CGRect(x: 0, y: 0, width: 100, height: 100)],
                displays: [CGRect(x: 0, y: 0, width: 1000, height: 800)]
            ),
            jobs: [
                OneShotCaptureBatch.Job {
                    await gate.enterAndWait()
                    return .thumbnail(101, smallImage)
                },
                OneShotCaptureBatch.Job {
                    await gate.enterAndWait()
                    return .thumbnail(202, nil)
                },
                OneShotCaptureBatch.Job {
                    await gate.enterAndWait()
                    return .desktopBackground(largeImage)
                },
            ],
            maximumConcurrentTasks: 2
        )
        let task = Task {
            await batch.run { events.append($0) }
        }

        await gate.waitUntilStarted(2)
        #expect(events.values == ["frames:101"])
        let running = await gate.snapshot
        #expect(running.maximumActive == 2)

        await gate.release(1)
        await gate.waitUntilStarted(3)
        await gate.release(2)
        await task.value

        #expect(events.values.first == "frames:101")
        #expect(Set(events.values.dropFirst()) == [
            "thumbnail:101:8x8",
            "desktop:16x10",
        ])
    }

    @Test func cancellationPreventsQueuedCaptureJobsFromStartingOrPublishing() async throws {
        let gate = CaptureJobGate()
        let events = CaptureEventLog()
        let image = try #require(PlaceholderRenderer.render(
            bundleID: "com.does.not.exist",
            size: CGSize(width: 8, height: 8)
        ))
        let batch = OneShotCaptureBatch(
            frames: WindowFrameHarvest(frames: [:], displays: []),
            jobs: [
                OneShotCaptureBatch.Job {
                    await gate.enterAndWait()
                    return .thumbnail(101, image)
                },
                OneShotCaptureBatch.Job {
                    await gate.enterAndWait()
                    return .thumbnail(202, image)
                },
            ],
            maximumConcurrentTasks: 1
        )
        let task = Task {
            await batch.run { events.append($0) }
        }

        await gate.waitUntilStarted(1)
        task.cancel()
        await gate.release(1)
        await task.value

        let snapshot = await gate.snapshot
        #expect(snapshot.started == 1)
        #expect(events.values == ["frames:"])
    }
}

private actor CaptureJobGate {
    struct Snapshot: Sendable {
        let started: Int
        let maximumActive: Int
    }

    private var started = 0
    private var active = 0
    private var maximumActive = 0
    private var permits = 0
    private var permitWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var snapshot: Snapshot {
        Snapshot(started: started, maximumActive: maximumActive)
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

private final class CaptureEventLog: @unchecked Sendable {
    private let lockedValues = OSAllocatedUnfairLock(initialState: [String]())

    var values: [String] {
        lockedValues.withLock { $0 }
    }

    func append(_ event: CaptureEvent) {
        lockedValues.withLock { values in
            switch event {
            case .frames(let harvest):
                let ids = harvest.frames.keys.sorted().map(String.init).joined(separator: ",")
                values.append("frames:\(ids)")
            case .desktopBackground(let image):
                values.append("desktop:\(image.width)x\(image.height)")
            case .thumbnail(let id, let image):
                values.append("thumbnail:\(id):\(image.width)x\(image.height)")
            }
        }
    }
}

import CoreGraphics
import Darwin
import Testing
@testable import AeroSpacePreview

@Suite struct LiveThumbnailCoordinatorTests {
    @Test func emptyRequestFinishesWithoutLoadingTargets() async {
        let loadCount = AsyncCountLatch()
        let coordinator = LiveThumbnailCoordinator { _ in
            await loadCount.increment()
            return []
        }

        let capture = coordinator.start(for: [], maxPixel: 320)
        var iterator = capture.frames.makeAsyncIterator()

        #expect(await iterator.next() == nil)
        #expect(await loadCount.value == 0)
    }

    @Test func partialStartupPublishesSuccessfulFramesAndRecordsFailures() async throws {
        let image = try #require(PlaceholderRenderer.render(
            bundleID: "com.does.not.exist",
            size: CGSize(width: 18, height: 12)
        ))
        let requestedIDs = WindowIDRecorder()
        let stopCount = AsyncCountLatch()
        let coordinator = LiveThumbnailCoordinator { wanted in
            await requestedIDs.record(wanted)
            return [
                LiveThumbnailCoordinator.Target(windowID: 101) {
                    maxPixel,
                    framesPerSecond,
                    delivery,
                    _ in
                    #expect(maxPixel == 320)
                    #expect(framesPerSecond == 24)
                    delivery.publish(LiveThumbnailFrame(
                        windowID: 101,
                        image: image,
                        diagnosticsTiming: nil
                    ))
                    return { await stopCount.increment() }
                },
                LiveThumbnailCoordinator.Target(windowID: 202) { _, _, _, _ in
                    throw CoordinatorTestError.startFailed
                },
            ]
        }
        let diagnostics = CaptureDiagnostics()
        diagnostics.prepareSummon(windowIDs: [101, 202, 303])
        let start = mach_absolute_time()
        diagnostics.beginSession(windowLabels: [101: "Editor", 202: "Browser"], now: start)

        let capture = coordinator.start(
            for: [101, 202],
            maxPixel: 320,
            framesPerSecond: 24,
            diagnostics: diagnostics
        )
        var iterator = capture.frames.makeAsyncIterator()
        let frame = try #require(await iterator.next())
        #expect(frame.windowID == 101)
        #expect(frame.image.width == 18)

        capture.stop()
        capture.stop()
        await stopCount.wait(until: 1)

        let snapshot = try #require(diagnostics.makeSnapshot(
            now: start + DiagnosticsMachClock.ticks(seconds: 1)
        ))
        #expect(await requestedIDs.value == Set([101, 202]))
        #expect(snapshot.capture.requestedWindowCount == 3)
        #expect(snapshot.capture.streamsStarted == 1)
        #expect(snapshot.capture.streamStartupFailures == 1)
        #expect(await stopCount.value == 1)
    }

    @Test func cancellationDuringStartupStopsAHandleInstalledLater() async {
        let gate = CoordinatorStartGate()
        let stopCount = AsyncCountLatch()
        let coordinator = LiveThumbnailCoordinator { _ in
            [LiveThumbnailCoordinator.Target(windowID: 101) { _, _, _, _ in
                await gate.startAndWaitForRelease()
                return { await stopCount.increment() }
            }]
        }

        let capture = coordinator.start(for: [101], maxPixel: 320)
        await gate.waitUntilStarted()
        capture.stop()
        await gate.release()
        await stopCount.wait(until: 1)

        var iterator = capture.frames.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        #expect(await stopCount.value == 1)
    }

    @Test func discoveryFailureFinishesTheFrameSequence() async {
        let coordinator = LiveThumbnailCoordinator { _ in
            throw CoordinatorTestError.discoveryFailed
        }

        let capture = coordinator.start(for: [101], maxPixel: 320)
        var iterator = capture.frames.makeAsyncIterator()

        #expect(await iterator.next() == nil)
    }
}

private enum CoordinatorTestError: Error {
    case discoveryFailed
    case startFailed
}

private actor WindowIDRecorder {
    private(set) var value: Set<CGWindowID> = []

    func record(_ ids: Set<CGWindowID>) {
        value = ids
    }
}

private actor AsyncCountLatch {
    private(set) var value = 0
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func increment() {
        value += 1
        let ready = waiters.filter { value >= $0.target }
        waiters.removeAll { value >= $0.target }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func wait(until target: Int) async {
        guard value < target else { return }
        await withCheckedContinuation { continuation in
            waiters.append((target, continuation))
        }
    }
}

private actor CoordinatorStartGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func startAndWaitForRelease() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

import CoreGraphics
import os
import ScreenCaptureKit
import Testing
@testable import AeroSpacePreview

@Suite struct LiveThumbnailTests {
    @Test func liveStreamsUseScreenCaptureKitsMinimumQueueDepth() {
        #expect(CaptureService.liveStreamQueueDepth == 3)
    }

    @Test func publishesOnlyDisplayableChangedFrames() {
        #expect(CaptureService.shouldPublish(frameStatus: .started))
        #expect(CaptureService.shouldPublish(frameStatus: .complete))
        #expect(!CaptureService.shouldPublish(frameStatus: .idle))
        #expect(!CaptureService.shouldPublish(frameStatus: .blank))
        #expect(!CaptureService.shouldPublish(frameStatus: .suspended))
        #expect(!CaptureService.shouldPublish(frameStatus: .stopped))
    }

    @Test func identifiesTheWallpaperWindowForItsDisplay() {
        let display = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        #expect(CaptureService.isWallpaperWindow(
            bundleIdentifier: "com.apple.dock",
            title: "Wallpaper-",
            frame: display,
            displayFrame: display
        ))
        #expect(!CaptureService.isWallpaperWindow(
            bundleIdentifier: "com.apple.finder",
            title: "Wallpaper-",
            frame: display,
            displayFrame: display
        ))
        #expect(!CaptureService.isWallpaperWindow(
            bundleIdentifier: "com.apple.dock",
            title: "Wallpaper-",
            frame: display.offsetBy(dx: 2560, dy: 0),
            displayFrame: display
        ))
    }

    @Test @MainActor func keepsStablePerWindowSlotsAndLastGoodImage() {
        let firstID: CGWindowID = 101
        let secondID: CGWindowID = 202
        let store = ThumbnailStore(windowIDs: [firstID, secondID])
        let firstSlot = store.slot(for: firstID)

        #expect(firstSlot === store.slot(for: firstID))
        #expect(firstSlot.image == nil)
        #expect(store.slot(for: secondID).image == nil)

        let image = PlaceholderRenderer.render(
            bundleID: "com.does.not.exist",
            size: CGSize(width: 64, height: 40)
        )
        store.update(image, for: firstID)
        #expect(firstSlot.image?.width == 64)
        #expect(store.slot(for: secondID).image == nil)

        store.update(nil, for: firstID)
        #expect(firstSlot.image?.width == 64)
    }

    @Test func streamCleanupIsIdempotentAndStopsLateInstallations() async {
        let counter = StopCounter()
        let lifetime = LiveStreamLifetime()
        await lifetime.install([{ await counter.increment() }])

        async let firstStop: Void = lifetime.stop()
        async let duplicateStop: Void = lifetime.stop()
        _ = await (firstStop, duplicateStop)
        var count = await counter.value
        #expect(count == 1)

        await lifetime.install([{ await counter.increment() }])
        count = await counter.value
        #expect(count == 2)
    }

    @Test func explicitlyStoppingLiveCaptureFinishesFramesAndRunsCleanupOnce() async throws {
        let buffer = LatestByKeyBuffer<CGWindowID, LiveThumbnailFrame>()
        let stopCounter = SynchronousStopCounter()
        let image = try #require(PlaceholderRenderer.render(
            bundleID: "com.does.not.exist",
            size: CGSize(width: 8, height: 8)
        ))
        let capture = LiveThumbnailCapture(
            next: { await buffer.next() },
            stopOperation: {
                stopCounter.increment()
                _ = buffer.finish()
            }
        )
        let consumer = Task {
            for await _ in capture.frames {}
        }

        await Task.yield()
        capture.stop()
        await consumer.value
        capture.stop()

        #expect(stopCounter.value == 1)
        #expect(!buffer.submit(LiveThumbnailFrame(
            windowID: 101,
            image: image,
            diagnosticsTiming: nil
        ), for: 101).accepted)
    }

    @Test func coalescesToTheNewestPendingFrame() {
        let coalescer = LatestFrameCoalescer<Int>()

        let first = coalescer.submit(1)
        #expect(first.shouldStartProcessing)
        #expect(first.replacedElement == nil)

        let second = coalescer.submit(2)
        #expect(!second.shouldStartProcessing)
        #expect(second.replacedElement == nil)

        let third = coalescer.submit(3)
        #expect(!third.shouldStartProcessing)
        #expect(third.replacedElement == 2)

        #expect(coalescer.next() == 3)
        #expect(coalescer.next() == nil)
        #expect(coalescer.submit(4).shouldStartProcessing)
    }

    @Test func stoppedCoalescerRejectsAndClearsPendingFrames() {
        let coalescer = LatestFrameCoalescer<Int>()
        _ = coalescer.submit(1)
        _ = coalescer.submit(2)

        #expect(coalescer.stop() == 2)
        #expect(!coalescer.isActive)
        #expect(coalescer.next() == nil)

        let rejected = coalescer.submit(3)
        #expect(!rejected.shouldStartProcessing)
        #expect(rejected.replacedElement == 3)
    }

    @Test func keyedBufferKeepsOnlyTheNewestFramePerWindow() async {
        let buffer = LatestByKeyBuffer<CGWindowID, Int>()
        let firstID: CGWindowID = 101
        let secondID: CGWindowID = 202

        _ = buffer.submit(1, for: firstID)
        _ = buffer.submit(10, for: secondID)
        var replaced: Int?
        for frame in 2...100 {
            replaced = buffer.submit(frame, for: firstID).replacedElement
        }

        #expect(replaced == 99)
        #expect(buffer.pendingCount == 2)
        #expect(await buffer.next() == 100)
        #expect(await buffer.next() == 10)
    }

    @Test func keyedBufferFinishesAndRejectsFurtherFrames() async {
        let buffer = LatestByKeyBuffer<CGWindowID, Int>()
        _ = buffer.submit(1, for: 101)
        _ = buffer.submit(2, for: 202)

        #expect(buffer.finish() == [1, 2])
        #expect(buffer.pendingCount == 0)
        #expect(await buffer.next() == nil)
        #expect(!buffer.submit(3, for: 303).accepted)
    }

    @Test func cancellingPullBasedStreamFinishesWaitingKeyedBuffer() async {
        let buffer = LatestByKeyBuffer<CGWindowID, Int>()
        let stream = AsyncStream(
            unfolding: { await buffer.next() },
            onCancel: { _ = buffer.finish() }
        )
        let consumer = Task {
            for await _ in stream {}
        }

        await Task.yield()
        consumer.cancel()
        await consumer.value

        #expect(!buffer.submit(1, for: 101).accepted)
    }
}

private final class SynchronousStopCounter: @unchecked Sendable {
    private let lockedValue = OSAllocatedUnfairLock(initialState: 0)

    var value: Int {
        lockedValue.withLock { $0 }
    }

    func increment() {
        lockedValue.withLock { $0 += 1 }
    }
}

private actor StopCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

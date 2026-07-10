import CoreGraphics
import ScreenCaptureKit
import Testing
@testable import AeroSpacePreview

@Suite struct LiveThumbnailTests {
    @Test func publishesOnlyDisplayableChangedFrames() {
        #expect(CaptureService.shouldPublish(frameStatus: .started))
        #expect(CaptureService.shouldPublish(frameStatus: .complete))
        #expect(!CaptureService.shouldPublish(frameStatus: .idle))
        #expect(!CaptureService.shouldPublish(frameStatus: .blank))
        #expect(!CaptureService.shouldPublish(frameStatus: .suspended))
        #expect(!CaptureService.shouldPublish(frameStatus: .stopped))
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
}

private actor StopCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

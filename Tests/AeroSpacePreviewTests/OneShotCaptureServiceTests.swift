import CoreGraphics
import os
import Testing
@testable import AeroSpacePreview

@Suite struct OneShotCaptureServiceTests {
    @Test func filtersMissingWindowsAndPublishesGeometryBeforeImages() async throws {
        let calls = LockedStringLog()
        let thumbnail = try #require(makeImage(width: 12, height: 8))
        let background = try #require(makeImage(width: 40, height: 24))
        let display = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let source = OneShotCaptureSource { excludingDesktopWindows, onScreenWindowsOnly in
            calls.append("load:\(excludingDesktopWindows):\(onScreenWindowsOnly)")
            return OneShotCaptureSource.Content(
                windows: [
                    OneShotCaptureSource.Window(
                        id: 101,
                        frame: CGRect(x: 10, y: 20, width: 600, height: 400),
                        capture: { maxPixel in
                            calls.append("window:101:\(maxPixel)")
                            return thumbnail
                        }
                    ),
                    OneShotCaptureSource.Window(
                        id: 202,
                        frame: CGRect(x: 700, y: 20, width: 600, height: 400),
                        capture: { maxPixel in
                            calls.append("window:202:\(maxPixel)")
                            return thumbnail
                        }
                    ),
                ],
                displayFrames: [display],
                captureDesktop: { displayID, maxPixel in
                    calls.append("desktop:\(displayID):\(maxPixel)")
                    return background
                }
            )
        }
        let service = OneShotCaptureService(source: source)

        var eventNames: [String] = []
        for await event in service.captureStream(
            for: [999, 101],
            maxPixel: 320,
            desktopDisplayID: 7,
            desktopMaxPixel: 1200
        ) {
            switch event {
            case .frames(let harvest):
                eventNames.append("frames")
                #expect(harvest.frames.keys.sorted() == [101])
                #expect(harvest.frames[101]?.origin == CGPoint(x: 10, y: 20))
                #expect(harvest.displays == [display])
            case .desktopBackground(let image):
                eventNames.append("desktop:\(image.width)x\(image.height)")
            case .thumbnail(let id, let image):
                eventNames.append("thumbnail:\(id):\(image.width)x\(image.height)")
            }
        }

        #expect(eventNames.first == "frames")
        #expect(Set(eventNames.dropFirst()) == ["desktop:40x24", "thumbnail:101:12x8"])
        #expect(Set(calls.values) == [
            "load:false:false",
            "window:101:320",
            "desktop:7:1200",
        ])
    }

    @Test func omitsFailedAndTimedOutCaptures() async throws {
        let image = try #require(makeImage(width: 8, height: 8))
        let source = OneShotCaptureSource { _, _ in
            OneShotCaptureSource.Content(
                windows: [
                    OneShotCaptureSource.Window(id: 101, frame: .zero) { _ in
                        throw TestCaptureError.failed
                    },
                    OneShotCaptureSource.Window(id: 202, frame: .zero) { _ in
                        try await Task.sleep(for: .seconds(10))
                        return image
                    },
                ],
                displayFrames: [],
                captureDesktop: { _, _ in nil }
            )
        }
        let service = OneShotCaptureService(
            perWindowTimeout: .milliseconds(10),
            source: source
        )

        var eventCount = 0
        for await event in service.captureStream(for: [101, 202], maxPixel: 320) {
            eventCount += 1
            guard case .frames(let harvest) = event else {
                Issue.record("failed or timed-out captures must not publish image events")
                continue
            }
            #expect(harvest.frames.keys.sorted() == [101, 202])
        }

        #expect(eventCount == 1)
    }

    @Test func frameHarvestWarmUpAndBatchWrapperUseTheInjectedSource() async throws {
        let calls = LockedStringLog()
        let firstImage = try #require(makeImage(width: 8, height: 8))
        let secondImage = try #require(makeImage(width: 16, height: 10))
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let source = OneShotCaptureSource { excludingDesktopWindows, onScreenWindowsOnly in
            calls.append("load:\(excludingDesktopWindows):\(onScreenWindowsOnly)")
            return OneShotCaptureSource.Content(
                windows: [
                    OneShotCaptureSource.Window(id: 101, frame: CGRect(x: 1, y: 2, width: 3, height: 4)) {
                        maxPixel in
                        calls.append("window:101:\(maxPixel)")
                        return firstImage
                    },
                    OneShotCaptureSource.Window(id: 202, frame: CGRect(x: 5, y: 6, width: 7, height: 8)) {
                        maxPixel in
                        calls.append("window:202:\(maxPixel)")
                        return secondImage
                    },
                ],
                displayFrames: [display],
                captureDesktop: { _, _ in nil }
            )
        }
        let service = OneShotCaptureService(source: source)

        let harvest = try #require(await service.windowFrames(for: [202, 999]))
        #expect(harvest.frames == [202: CGRect(x: 5, y: 6, width: 7, height: 8)])
        #expect(harvest.displays == [display])

        await service.warmUp()
        let images = await service.thumbnails(for: [202], maxPixel: 64)
        #expect(images.keys.sorted() == [202])
        #expect(images[202]?.width == 16)
        #expect(calls.values == [
            "load:false:false",
            "load:true:true",
            "window:101:8",
            "load:false:false",
            "window:202:64",
        ])
    }

    @Test func sourceFailureFinishesWithoutEventsOrGeometry() async {
        let source = OneShotCaptureSource { _, _ in
            throw TestCaptureError.failed
        }
        let service = OneShotCaptureService(source: source)

        var receivedEvent = false
        for await _ in service.captureStream(for: [101], maxPixel: 320) {
            receivedEvent = true
        }

        #expect(!receivedEvent)
        #expect(await service.windowFrames(for: [101]) == nil)
        await service.warmUp()
    }

    private func makeImage(width: Int, height: Int) -> CGImage? {
        PlaceholderRenderer.render(
            bundleID: "com.does.not.exist",
            size: CGSize(width: width, height: height)
        )
    }
}

private enum TestCaptureError: Error {
    case failed
}

private final class LockedStringLog: @unchecked Sendable {
    private let lockedValues = OSAllocatedUnfairLock(initialState: [String]())

    var values: [String] {
        lockedValues.withLock { $0 }
    }

    func append(_ value: String) {
        lockedValues.withLock { $0.append(value) }
    }
}

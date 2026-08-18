import CoreGraphics
import Darwin
import Testing
@testable import AeroSpacePreview

@MainActor
@Suite struct OverlayCaptureConsumerTests {
    @Test func oneShotEventsPublishLayoutBackgroundAndThumbnailsInTheCurrentSession() async throws {
        let thumbnail = try #require(makeImage(width: 12, height: 8))
        let background = try #require(makeImage(width: 32, height: 20))
        let content = makeContent()
        let viewModel = OverlayViewModel(content: content, actions: actions)
        let frameCache = FrameCacheStore()
        let display = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let stream = AsyncStream<CaptureEvent> { continuation in
            continuation.yield(.frames(WindowFrameHarvest(
                frames: [
                    101: CGRect(x: 0, y: 0, width: 800, height: 1000),
                    202: CGRect(x: 800, y: 0, width: 800, height: 1000),
                    999: CGRect(x: 0, y: 0, width: 100, height: 100),
                ],
                displays: [display]
            )))
            continuation.yield(.desktopBackground(background))
            continuation.yield(.thumbnail(101, thumbnail))
            continuation.finish()
        }
        var cachedDisplayID: CGDirectDisplayID?
        var cachedBackground: CGImage?

        let captured = await OverlayCaptureConsumer.consumeOneShotEvents(
            stream,
            content: content,
            targetDisplayID: 7,
            viewModel: viewModel,
            frameCache: frameCache,
            isCurrent: { true },
            cacheDesktopBackground: { displayID, image in
                cachedDisplayID = displayID
                cachedBackground = image
            }
        )

        #expect(captured == 1)
        #expect(viewModel.layouts["dev"]?.frames.keys.sorted() == [101, 202])
        #expect(viewModel.layouts["dev"]?.frames[101]?.width == 0.5)
        #expect(viewModel.thumbnails.slot(for: 101).image?.width == 12)
        #expect(viewModel.desktopBackground?.width == 32)
        #expect(cachedDisplayID == 7)
        #expect(cachedBackground?.height == 20)
    }

    @Test func staleSessionRejectsOneShotEventsBeforeTheyMutateTheViewModel() async throws {
        let thumbnail = try #require(makeImage(width: 12, height: 8))
        let content = makeContent()
        let viewModel = OverlayViewModel(content: content, actions: actions)
        let stream = AsyncStream<CaptureEvent> { continuation in
            continuation.yield(.thumbnail(101, thumbnail))
            continuation.finish()
        }

        let captured = await OverlayCaptureConsumer.consumeOneShotEvents(
            stream,
            content: content,
            targetDisplayID: nil,
            viewModel: viewModel,
            frameCache: FrameCacheStore(),
            isCurrent: { false },
            cacheDesktopBackground: { _, _ in }
        )

        #expect(captured == nil)
        #expect(viewModel.thumbnails.slot(for: 101).image == nil)
    }

    @Test func liveFramesUpdateTheThumbnailAndCompleteDeliveryDiagnostics() async throws {
        let image = try #require(makeImage(width: 16, height: 10))
        let content = makeContent()
        let viewModel = OverlayViewModel(content: content, actions: actions)
        let diagnostics = CaptureDiagnostics()
        diagnostics.prepareSummon(windowIDs: [101])
        let start = mach_absolute_time()
        diagnostics.beginSession(windowLabels: [101: "Editor"], now: start)
        let timing = try #require(diagnostics.recordFrame(
            windowID: 101,
            status: .complete,
            width: image.width,
            height: image.height,
            windowServerDisplayMachTime: nil
        ))
        diagnostics.recordYielded(timing: timing)
        let frames = AsyncStream<LiveThumbnailFrame> { continuation in
            continuation.yield(LiveThumbnailFrame(
                windowID: 101,
                image: image,
                diagnosticsTiming: timing
            ))
            continuation.finish()
        }

        await OverlayCaptureConsumer.consumeLiveFrames(
            frames,
            viewModel: viewModel,
            diagnostics: diagnostics,
            isCurrent: { true }
        )

        let snapshot = try #require(diagnostics.makeSnapshot(
            now: start + DiagnosticsMachClock.ticks(seconds: 1)
        ))
        #expect(viewModel.thumbnails.slot(for: 101).image?.width == 16)
        #expect(snapshot.delivery.uiDeliveredFrames == 1)
        #expect(snapshot.delivery.currentBacklog == 0)
    }

    private var actions: OverlayActions {
        OverlayActions(
            dismiss: {},
            selectWorkspace: { _ in },
            focusWindow: { _ in }
        )
    }

    private func makeContent() -> OverlayContent {
        .snapshot(OverlaySnapshot(
            workspaces: [AeroSpaceWorkspace(
                name: "dev",
                isFocused: true,
                windows: [
                    AeroSpaceWindow(
                        id: 101,
                        appName: "Editor",
                        bundleID: "com.example.editor",
                        title: "Main"
                    ),
                    AeroSpaceWindow(
                        id: 202,
                        appName: "Terminal",
                        bundleID: "com.example.terminal",
                        title: "Shell"
                    ),
                ]
            )],
            permissionDenied: false
        ))
    }

    private func makeImage(width: Int, height: Int) -> CGImage? {
        PlaceholderRenderer.render(
            bundleID: "com.does.not.exist",
            size: CGSize(width: width, height: height)
        )
    }
}

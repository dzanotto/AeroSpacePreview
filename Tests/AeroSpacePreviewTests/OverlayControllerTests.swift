import Combine
import CoreGraphics
import Foundation
import Testing
@testable import AeroSpacePreview

@MainActor
@Suite struct OverlayControllerTests {
    @Test func secondToggleCancelsLoadingAndAllowsAReplacementSummon() async throws {
        let events = ControllerEvents()
        let presenter = ControllerPresenter(events: events)
        let controller = OverlayController(presenter: presenter, discoverClient: { nil }, loadContent: { _, _ in
            let call = await events.record("load")
            if call == 1 {
                return await withTaskCancellationHandler {
                    try? await events.wait("release first load")
                    await events.record("first load returned")
                    return .error("cancelled summon")
                } onCancel: {
                    Task { await events.record("first load cancelled") }
                }
            }
            return .error("replacement")
        })
        defer { controller.shutdown() }

        controller.toggle()
        try await events.wait("load")
        controller.toggle()
        try await events.wait("first load cancelled")
        #expect(!controller.isVisible)
        controller.toggle()
        try await events.wait("present")
        #expect(presenter.presentCount == 1)
        #expect(presenter.viewModel?.errorMessage == "replacement")

        await events.record("release first load")
        try await events.wait("first load returned")
        // The replacement is still active when the cancelled loader resumes.
        controller.hide()
        presenter.finishDismissal()
        controller.show()
        try await events.wait("present", count: 2)
        #expect(presenter.presentCount == 2)
        #expect(presenter.viewModel?.errorMessage == "replacement")
    }

    @Test func placeholdersPrecedePixelsAndLiveCaptureWaitsForTheOneShotPass() async throws {
        let events = ControllerEvents()
        let presenter = ControllerPresenter(events: events)
        let image = try #require(makeImage(width: 12))
        let source = makeSource(events: events) { _ in
            await events.record("screenshot started")
            try await events.wait("release screenshot")
            return image
        }
        let live = LiveThumbnailCoordinator { _ in
            await events.record("live discovery")
            return []
        }
        let controller = OverlayController(
            presenter: presenter,
            oneShotCapture: OneShotCaptureService(perWindowTimeout: .seconds(10), source: source),
            liveThumbnails: live,
            discoverClient: { nil },
            loadContent: { _, _ in Self.content() }
        )
        defer { controller.shutdown() }

        controller.show()
        try await events.wait("screenshot started")
        let model = try #require(presenter.viewModel)
        #expect(presenter.hadPlaceholderAtPresentation)
        #expect(model.thumbnails.slot(for: 101).image == nil)
        #expect(await events.count("live discovery") == 0)

        await events.record("release screenshot")
        try await events.wait("live discovery")
        #expect(model.thumbnails.slot(for: 101).image?.width == 12)
    }

    @Test func hidingStopsLiveCaptureOnceAndIgnoresTogglesUntilTheFadeCompletes() async throws {
        let events = ControllerEvents()
        let presenter = ControllerPresenter(events: events)
        let still = try #require(makeImage(width: 12))
        let liveImage = try #require(makeImage(width: 24))
        let lateImage = try #require(makeImage(width: 36))
        let deliveries = ControllerDeliveryStore()
        let live = LiveThumbnailCoordinator { _ in
            [LiveThumbnailCoordinator.Target(windowID: 101) { _, _, delivery, _ in
                await deliveries.set(delivery)
                await events.record("live started")
                return { await events.record("live stopped") }
            }]
        }
        let controller = OverlayController(
            presenter: presenter,
            oneShotCapture: OneShotCaptureService(source: makeSource(events: events) { _ in still }),
            liveThumbnails: live,
            discoverClient: { nil },
            loadContent: { _, _ in Self.content() }
        )
        defer { controller.shutdown() }

        controller.show()
        try await events.wait("live started")
        let model = try #require(presenter.viewModel)
        let subscription = model.thumbnails.slot(for: 101).$image.sink { image in
            if image?.width == 24 {
                Task { await events.record("live image applied") }
            }
        }
        defer { subscription.cancel() }
        await deliveries.publish(liveImage)
        try await events.wait("live image applied")
        #expect(model.thumbnails.slot(for: 101).image?.width == 24)

        controller.toggle()
        #expect(presenter.dismissCount == 1)
        controller.toggle()
        controller.show()
        #expect(presenter.presentCount == 1)
        #expect(presenter.dismissCount == 1)
        try await events.wait("live stopped")
        await deliveries.publish(lateImage)
        #expect(model.thumbnails.slot(for: 101).image?.width == 24)

        presenter.finishDismissal()
        #expect(presenter.viewModel == nil)
        #expect(!controller.isVisible)
        controller.toggle()
        try await events.wait("present", count: 2)
        #expect(controller.isVisible)
        #expect(await events.count("live stopped") == 1)
        try await events.wait("live started", count: 2)
        controller.shutdown()
        controller.shutdown()
        try await events.wait("live stopped", count: 2)
        #expect(await events.count("live stopped") == 2)
        #expect(presenter.viewModel == nil)
        #expect(!controller.isVisible)
    }

    @Test func dismissalDuringOneShotCaptureRejectsLatePixelsAndDoesNotStartLiveCapture() async throws {
        let events = ControllerEvents()
        let presenter = ControllerPresenter(events: events)
        let image = try #require(makeImage(width: 12))
        let source = makeSource(events: events) { _ in
            await events.record("screenshot started")
            try await events.wait("release screenshot")
            await events.record("screenshot returned")
            return image
        }
        let controller = OverlayController(
            presenter: presenter,
            oneShotCapture: OneShotCaptureService(perWindowTimeout: .seconds(10), source: source),
            liveThumbnails: LiveThumbnailCoordinator { _ in
                await events.record("live discovery")
                return []
            },
            discoverClient: { nil },
            loadContent: { _, _ in Self.content() }
        )
        defer { controller.shutdown() }

        controller.show()
        try await events.wait("screenshot started")
        weak let model = presenter.viewModel
        let slot = try #require(model).thumbnails.slot(for: 101)
        controller.hide()
        presenter.finishDismissal()
        try await expectEventually { model == nil }
        await events.record("release screenshot")
        try await events.wait("screenshot returned")
        #expect(slot.image == nil)
        #expect(await events.count("live discovery") == 0)
    }

    @Test(arguments: [false, true])
    func errorAndPermissionDeniedContentDoNotStartCapture(permissionDenied: Bool) async throws {
        let events = ControllerEvents()
        let presenter = ControllerPresenter(events: events)
        let controller = OverlayController(
            presenter: presenter,
            oneShotCapture: OneShotCaptureService(source: makeSource(events: events)),
            liveThumbnails: LiveThumbnailCoordinator { _ in
                await events.record("live discovery")
                return []
            },
            discoverClient: { nil },
            loadContent: { _, _ in
                permissionDenied ? Self.content(permissionDenied: true) : .error("unavailable")
            }
        )
        defer { controller.shutdown() }

        controller.show()
        try await events.wait("present")
        #expect(controller.isVisible)
        #expect(await events.count("source load") == 0)
        #expect(await events.count("live discovery") == 0)
        if permissionDenied {
            guard case .snapshot(let snapshot) = presenter.viewModel?.content else {
                Issue.record("Expected permission-denied content")
                return
            }
            #expect(snapshot.permissionDenied)
        } else {
            #expect(presenter.viewModel?.errorMessage == "unavailable")
        }
    }

    @Test func unavailableDisplayAndFailedPresentationPermitRetryWithoutStartingCapture() async throws {
        let events = ControllerEvents()
        let presenter = ControllerPresenter(events: events)
        presenter.display = nil
        let controller = OverlayController(
            presenter: presenter,
            oneShotCapture: OneShotCaptureService(source: makeSource(events: events)),
            liveThumbnails: LiveThumbnailCoordinator { _ in [] },
            discoverClient: { nil },
            loadContent: { _, _ in
                await events.record("load")
                return Self.content()
            }
        )
        defer { controller.shutdown() }

        controller.show()
        #expect(!controller.isVisible)
        #expect(await events.count("load") == 0)
        presenter.display = OverlayDisplayTarget(displayID: 7)
        presenter.shouldPresent = false
        controller.show()
        try await events.wait("present")
        #expect(!controller.isVisible)
        #expect(await events.count("source load") == 0)
        #expect(presenter.viewModel == nil)

        presenter.shouldPresent = true
        controller.show()
        try await events.wait("source load")
        #expect(controller.isVisible)
        #expect(presenter.presentCount == 2)
    }

    @Test func endedSessionCallbacksCannotDismissOrClearAReplacement() async throws {
        let events = ControllerEvents()
        let presenter = ControllerPresenter(events: events)
        let controller = OverlayController(presenter: presenter, discoverClient: { nil }, loadContent: { _, _ in .error("ready") })
        defer { controller.shutdown() }

        controller.show()
        try await events.wait("present")
        let oldModel = try #require(presenter.viewModel)
        let oldDismiss = try #require(presenter.onDismiss)
        controller.hide()
        let oldCompletion = try #require(presenter.dismissalCompletion)
        presenter.finishDismissal()
        controller.show()
        try await events.wait("present", count: 2)
        let replacement = try #require(presenter.viewModel)

        oldDismiss()
        oldModel.actions.dismiss()
        oldModel.actions.selectWorkspace("dev")
        oldModel.actions.focusWindow(101)
        oldCompletion()

        #expect(presenter.viewModel === replacement)
        #expect(controller.isVisible)
        #expect(presenter.dismissCount == 1)
    }

    @Test func shutdownDuringLoadingRejectsLateResultsAndNewSummons() async throws {
        let events = ControllerEvents()
        let presenter = ControllerPresenter(events: events)
        let controller = OverlayController(presenter: presenter, discoverClient: { nil }, loadContent: { _, _ in
            await events.record("load")
            try? await events.wait("release load")
            await events.record("load returned")
            return .error("too late")
        })

        controller.show()
        try await events.wait("load")
        controller.shutdown()
        controller.show()
        controller.toggle()
        await events.record("release load")
        try await events.wait("load returned")
        #expect(await events.count("load") == 1)
        #expect(presenter.presentCount == 0)
        #expect(presenter.viewModel == nil)
        #expect(!controller.isVisible)
    }

    @Test func shutdownClearsThePresentationBeforePendingDismissalCompletes() async throws {
        let events = ControllerEvents()
        let presenter = ControllerPresenter(events: events)
        let controller = OverlayController(presenter: presenter, discoverClient: { nil }, loadContent: { _, _ in .error("ready") })

        controller.show()
        try await events.wait("present")
        weak let model = presenter.viewModel
        controller.hide()
        let completion = try #require(presenter.dismissalCompletion)
        controller.shutdown()
        #expect(presenter.viewModel == nil)
        #expect(presenter.onDismiss == nil)
        completion()
        controller.toggle()
        #expect(presenter.presentCount == 1)
        #expect(!controller.isVisible)
        try await expectEventually { model == nil }
    }

    @Test func dismissalReleasesSessionImagesButRetainsWallpaperAndLayoutForTheNextSummon() async throws {
        let events = ControllerEvents()
        let presenter = ControllerPresenter(events: events)
        let thumbnail = try #require(makeImage(width: 12))
        let wallpaper = try #require(makeImage(width: 40))
        let source = makeSource(events: events, wallpaper: wallpaper) { _ in thumbnail }
        let controller = OverlayController(
            presenter: presenter,
            oneShotCapture: OneShotCaptureService(source: source),
            liveThumbnails: LiveThumbnailCoordinator { _ in
                await events.record("live discovery")
                return []
            },
            discoverClient: { nil },
            loadContent: { _, _ in Self.content() }
        )
        defer { controller.shutdown() }

        controller.show()
        try await events.wait("live discovery")
        weak let oldModel = presenter.viewModel
        #expect(oldModel?.desktopBackground?.width == 40)
        #expect(oldModel?.layouts["dev"]?.frames[101]?.width == 0.5)
        controller.hide()
        presenter.finishDismissal()
        try await expectEventually { oldModel == nil }

        controller.show()
        try await events.wait("present", count: 2)
        #expect(presenter.backgroundWidthAtPresentation == 40)
        #expect(presenter.layoutWidthAtPresentation == 0.5)
        #expect(presenter.hadPlaceholderAtPresentation)
    }

    private nonisolated static func content(permissionDenied: Bool = false) -> OverlayContent {
        .snapshot(OverlaySnapshot(workspaces: [
            AeroSpaceWorkspace(name: "dev", isFocused: true, windows: [
                AeroSpaceWindow(id: 101, appName: "Editor", bundleID: "com.example.editor", title: "Main"),
            ]),
        ], permissionDenied: permissionDenied))
    }

    private func makeImage(width: Int) -> CGImage? {
        PlaceholderRenderer.render(bundleID: "com.does.not.exist", size: CGSize(width: width, height: 8))
    }

    private func makeSource(
        events: ControllerEvents,
        wallpaper: CGImage? = nil,
        capture: (@Sendable (Int) async throws -> CGImage)? = nil
    ) -> OneShotCaptureSource {
        OneShotCaptureSource { _, _ in
            await events.record("source load")
            return OneShotCaptureSource.Content(
                windows: capture.map { operation in
                    [OneShotCaptureSource.Window(
                        id: 101,
                        frame: CGRect(x: 0, y: 0, width: 800, height: 1000),
                        capture: operation
                    )]
                } ?? [],
                displayFrames: [CGRect(x: 0, y: 0, width: 1600, height: 1000)],
                captureDesktop: { _, _ in wallpaper }
            )
        }
    }

    private func expectEventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw ControllerTestError.timedOut("capture consumer release")
            }
            await Task.yield()
        }
    }
}

@MainActor
private final class ControllerPresenter: OverlayPresenting {
    var display: OverlayDisplayTarget? = OverlayDisplayTarget(displayID: 7)
    var shouldPresent = true
    private(set) var isVisible = false
    private(set) var viewModel: OverlayViewModel?
    private(set) var presentCount = 0
    private(set) var dismissCount = 0
    private(set) var hadPlaceholderAtPresentation = false
    private(set) var backgroundWidthAtPresentation: Int?
    private(set) var layoutWidthAtPresentation: CGFloat?
    private(set) var onDismiss: (@MainActor () -> Void)?
    private(set) var dismissalCompletion: (@MainActor () -> Void)?
    private let events: ControllerEvents

    init(events: ControllerEvents) {
        self.events = events
    }

    func targetDisplay() -> OverlayDisplayTarget? { display }

    func present(
        _ viewModel: OverlayViewModel,
        on target: OverlayDisplayTarget,
        onDismiss: @escaping @MainActor () -> Void
    ) -> Bool {
        presentCount += 1
        defer { Task { await events.record("present") } }
        guard shouldPresent else { return false }
        self.viewModel = viewModel
        self.onDismiss = onDismiss
        hadPlaceholderAtPresentation = viewModel.thumbnails.slot(for: 101).image == nil
        backgroundWidthAtPresentation = viewModel.desktopBackground?.width
        layoutWidthAtPresentation = viewModel.layouts["dev"]?.frames[101]?.width
        isVisible = true
        return true
    }

    func dismiss(completion: @escaping @MainActor () -> Void) {
        dismissCount += 1
        onDismiss = nil
        dismissalCompletion = completion
    }

    func clear() {
        isVisible = false
        viewModel = nil
        onDismiss = nil
        dismissalCompletion = nil
    }

    func finishDismissal() {
        let completion = dismissalCompletion
        dismissalCompletion = nil
        completion?()
    }
}

private actor ControllerDeliveryStore {
    private var delivery: LiveFrameDelivery?

    func set(_ delivery: LiveFrameDelivery) {
        self.delivery = delivery
    }

    func publish(_ image: CGImage) {
        delivery?.publish(LiveThumbnailFrame(windowID: 101, image: image, diagnosticsTiming: nil))
    }
}

/// Every suspended test operation has a watchdog, including gates that
/// deliberately ignore task cancellation to simulate late platform results.
private actor ControllerEvents {
    private struct Waiter {
        let event: String
        let count: Int
        let continuation: CheckedContinuation<Void, Error>
        let watchdog: Task<Void, Never>
    }

    private var counts: [String: Int] = [:]
    private var waiters: [UUID: Waiter] = [:]

    @discardableResult
    func record(_ event: String) -> Int {
        counts[event, default: 0] += 1
        let count = counts[event, default: 0]
        let ready = waiters.filter { $0.value.event == event && $0.value.count <= count }
        for (id, waiter) in ready {
            waiters.removeValue(forKey: id)
            waiter.watchdog.cancel()
            waiter.continuation.resume()
        }
        return count
    }

    func count(_ event: String) -> Int { counts[event, default: 0] }

    func wait(_ event: String, count: Int = 1) async throws {
        guard counts[event, default: 0] < count else { return }
        let id = UUID()
        try await withCheckedThrowingContinuation { continuation in
            let watchdog = Task {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                expire(id)
            }
            waiters[id] = Waiter(event: event, count: count, continuation: continuation, watchdog: watchdog)
        }
    }

    private func expire(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: ControllerTestError.timedOut(waiter.event))
    }
}

private enum ControllerTestError: Error {
    case timedOut(String)
}

@MainActor
private extension OverlayViewModel {
    var errorMessage: String? {
        guard case .error(let message) = content else { return nil }
        return message
    }
}

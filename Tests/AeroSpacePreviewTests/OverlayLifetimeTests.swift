import os
import Testing
@testable import AeroSpacePreview

@MainActor
@Suite struct OverlayLifetimeTests {
    @Test func followsTheOverlaySessionTransitionOrder() throws {
        let lifetime = OverlayLifetime()

        let sessionID = try #require(lifetime.beginLoading())
        #expect(lifetime.phase == .loading)
        #expect(lifetime.beginLoading() == nil)

        #expect(lifetime.markVisible(sessionID))
        #expect(lifetime.phase == .visible)
        #expect(!lifetime.markVisible(sessionID))

        #expect(lifetime.beginHiding() == sessionID)
        #expect(lifetime.phase == .hiding)
        #expect(lifetime.beginHiding() == nil)

        #expect(lifetime.finishHiding(sessionID))
        #expect(lifetime.phase == .idle)
        #expect(lifetime.currentSessionID == nil)
    }

    @Test func staleSessionCannotTransitionAReplacementSession() throws {
        let lifetime = OverlayLifetime()
        let first = try #require(lifetime.beginLoading())
        #expect(lifetime.abort(first))

        let replacement = try #require(lifetime.beginLoading())
        #expect(!lifetime.markVisible(first))
        #expect(!lifetime.finishHiding(first))
        #expect(lifetime.isCurrent(replacement, phase: .loading))
        #expect(lifetime.markVisible(replacement))
    }

    @Test func hidingStopsCaptureAndLiveWorkWhileDiagnosticsStopExplicitly() async throws {
        let lifetime = OverlayLifetime()
        let captureCancellations = LockedCounter()
        let diagnosticsCancellations = LockedCounter()
        let liveStops = LockedCounter()
        let sessionID = try #require(lifetime.beginLoading())

        let captureTask = cancellableTask(recordingWith: captureCancellations)
        #expect(lifetime.installCaptureTask(captureTask, for: sessionID))
        #expect(lifetime.markVisible(sessionID))

        let diagnosticsTask = cancellableTask(recordingWith: diagnosticsCancellations)
        #expect(lifetime.installDiagnosticsTask(diagnosticsTask, for: sessionID))
        let liveCapture = LiveThumbnailCapture(
            next: { nil },
            stopOperation: { liveStops.increment() }
        )
        #expect(lifetime.installLiveCapture(liveCapture, for: sessionID))

        #expect(lifetime.beginHiding() == sessionID)
        lifetime.stopDiagnostics(for: sessionID)
        await captureTask.value
        await diagnosticsTask.value

        #expect(captureCancellations.value == 1)
        #expect(diagnosticsCancellations.value == 1)
        #expect(liveStops.value == 1)
        #expect(lifetime.finishHiding(sessionID))
        lifetime.shutdown()
        #expect(liveStops.value == 1)
    }

    @Test func invalidSessionRejectsLateWorkAndCleansItUp() async throws {
        let lifetime = OverlayLifetime()
        let captureCancellations = LockedCounter()
        let diagnosticsCancellations = LockedCounter()
        let liveStops = LockedCounter()
        let sessionID = try #require(lifetime.beginLoading())
        #expect(lifetime.abort(sessionID))

        let captureTask = cancellableTask(recordingWith: captureCancellations)
        #expect(!lifetime.installCaptureTask(captureTask, for: sessionID))
        let diagnosticsTask = cancellableTask(recordingWith: diagnosticsCancellations)
        #expect(!lifetime.installDiagnosticsTask(diagnosticsTask, for: sessionID))
        let liveCapture = LiveThumbnailCapture(
            next: { nil },
            stopOperation: { liveStops.increment() }
        )
        #expect(!lifetime.installLiveCapture(liveCapture, for: sessionID))

        await captureTask.value
        await diagnosticsTask.value
        #expect(captureCancellations.value == 1)
        #expect(diagnosticsCancellations.value == 1)
        #expect(liveStops.value == 1)
    }

    @Test func releasingLiveCaptureUsesCaptureIdentity() throws {
        let lifetime = OverlayLifetime()
        let firstStops = LockedCounter()
        let replacementStops = LockedCounter()
        let sessionID = try #require(lifetime.beginLoading())
        #expect(lifetime.markVisible(sessionID))

        let first = LiveThumbnailCapture(
            next: { nil },
            stopOperation: { firstStops.increment() }
        )
        let replacement = LiveThumbnailCapture(
            next: { nil },
            stopOperation: { replacementStops.increment() }
        )

        #expect(lifetime.installLiveCapture(first, for: sessionID))
        #expect(lifetime.installLiveCapture(replacement, for: sessionID))
        #expect(firstStops.value == 1)

        // Completion from the replaced capture must not release the current one.
        withExtendedLifetime(replacement) {
            lifetime.releaseLiveCapture(first, for: sessionID)
            #expect(lifetime.beginHiding() == sessionID)
            #expect(replacementStops.value == 1)
            #expect(lifetime.finishHiding(sessionID))
        }

        let nextSessionID = try #require(lifetime.beginLoading())
        #expect(lifetime.markVisible(nextSessionID))
        let completed = LiveThumbnailCapture(
            next: { nil },
            stopOperation: { replacementStops.increment() }
        )
        #expect(lifetime.installLiveCapture(completed, for: nextSessionID))

        // A naturally completed current capture no longer belongs to the lifetime.
        withExtendedLifetime(completed) {
            lifetime.releaseLiveCapture(completed, for: nextSessionID)
            #expect(lifetime.beginHiding() == nextSessionID)
            #expect(replacementStops.value == 1)
            #expect(lifetime.finishHiding(nextSessionID))
        }
    }

    @Test func postActionWorkOutlivesDismissalButReplacementAndShutdownCancelIt() async throws {
        let lifetime = OverlayLifetime()
        let firstCancellations = LockedCounter()
        let secondCancellations = LockedCounter()
        let first = cancellableTask(recordingWith: firstCancellations)
        let second = cancellableTask(recordingWith: secondCancellations)

        lifetime.replacePostActionTask(first)
        lifetime.replacePostActionTask(second)
        await first.value
        #expect(firstCancellations.value == 1)

        let sessionID = try #require(lifetime.beginLoading())
        #expect(lifetime.markVisible(sessionID))
        #expect(lifetime.beginHiding() == sessionID)
        #expect(lifetime.finishHiding(sessionID))
        #expect(secondCancellations.value == 0)

        lifetime.shutdown()
        await second.value
        #expect(secondCancellations.value == 1)
    }

    @Test func shutdownInvalidatesEveryActivePhaseAndRejectsLaterWork() throws {
        for targetPhase in [
            OverlayLifetime.Phase.loading,
            .visible,
            .hiding,
        ] {
            let lifetime = OverlayLifetime()
            let sessionID = try #require(lifetime.beginLoading())
            if targetPhase == .visible || targetPhase == .hiding {
                #expect(lifetime.markVisible(sessionID))
            }
            if targetPhase == .hiding {
                #expect(lifetime.beginHiding() == sessionID)
            }

            lifetime.shutdown()

            #expect(lifetime.phase == .idle)
            #expect(lifetime.currentSessionID == nil)
            #expect(!lifetime.isCurrent(sessionID))
            #expect(!lifetime.markVisible(sessionID))
            #expect(!lifetime.finishHiding(sessionID))
            #expect(lifetime.beginLoading() == nil)
        }
    }

    @Test func shutdownRejectsLatePostActionWork() async {
        let lifetime = OverlayLifetime()
        let cancellations = LockedCounter()
        lifetime.shutdown()

        let lateWork = cancellableTask(recordingWith: cancellations)
        lifetime.replacePostActionTask(lateWork)
        await lateWork.value

        #expect(cancellations.value == 1)
    }

    private func cancellableTask(recordingWith counter: LockedCounter) -> Task<Void, Never> {
        Task {
            await withTaskCancellationHandler {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    // Cancellation is the only expected completion path.
                }
            } onCancel: {
                counter.increment()
            }
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lockedValue = OSAllocatedUnfairLock(initialState: 0)

    var value: Int {
        lockedValue.withLock { $0 }
    }

    func increment() {
        lockedValue.withLock { $0 += 1 }
    }
}

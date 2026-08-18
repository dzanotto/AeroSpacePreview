import CoreGraphics
import Darwin
import ScreenCaptureKit
import Testing
@testable import AeroSpacePreview

@Suite struct DiagnosticsMathTests {
    @Test func calculatesRatesFromCounterDeltasAndElapsedTime() {
        #expect(DiagnosticsMath.rate(delta: 25, elapsedSeconds: 0.5) == 50)
        #expect(DiagnosticsMath.rate(delta: 25, elapsedSeconds: 0) == 0)
    }

    @Test func calculatesActivityMonitorStyleCPUAndWakeupRates() throws {
        let previous = ProcessResourceSample(
            wallTimeNanoseconds: 1_000_000_000,
            cpuTimeNanoseconds: 2_000_000_000,
            physicalFootprintBytes: 100,
            packageIdleWakeups: 20
        )
        let current = ProcessResourceSample(
            wallTimeNanoseconds: 3_000_000_000,
            cpuTimeNanoseconds: 5_000_000_000,
            physicalFootprintBytes: 200,
            packageIdleWakeups: 40
        )
        let delta = try #require(ProcessResourceMath.delta(from: previous, to: current))
        #expect(delta.cpuPercentage == 150)
        #expect(delta.packageIdleWakeupsPerSecond == 10)
    }

    @Test func convertsProcessCPUMachTicksToNanoseconds() throws {
        let nanoseconds = try #require(ProcessResourceMath.nanoseconds(
            fromMachTicks: 24_000_000,
            numerator: 125,
            denominator: 3
        ))

        #expect(nanoseconds == 1_000_000_000)
        #expect(ProcessResourceMath.nanoseconds(
            fromMachTicks: 1,
            numerator: 1,
            denominator: 0
        ) == nil)
    }

    @Test func rejectsNonMonotonicResourceSamplesAndArithmeticOverflow() {
        let baseline = ProcessResourceSample(
            wallTimeNanoseconds: 10,
            cpuTimeNanoseconds: 20,
            physicalFootprintBytes: 30,
            packageIdleWakeups: 40
        )
        #expect(ProcessResourceMath.delta(from: baseline, to: .init(
            wallTimeNanoseconds: 10,
            cpuTimeNanoseconds: 21,
            physicalFootprintBytes: 30,
            packageIdleWakeups: 41
        )) == nil)
        #expect(ProcessResourceMath.delta(from: baseline, to: .init(
            wallTimeNanoseconds: 11,
            cpuTimeNanoseconds: 19,
            physicalFootprintBytes: 30,
            packageIdleWakeups: 41
        )) == nil)
        #expect(ProcessResourceMath.delta(from: baseline, to: .init(
            wallTimeNanoseconds: 11,
            cpuTimeNanoseconds: 21,
            physicalFootprintBytes: 30,
            packageIdleWakeups: 39
        )) == nil)
        #expect(ProcessResourceMath.nanoseconds(
            fromMachTicks: UInt64.max,
            numerator: UInt32.max,
            denominator: 1
        ) == nil)
    }

    @Test func samplesTheCurrentProcessUsingTheSuppliedWallClockValue() throws {
        let sample = try #require(ProcessResourceSampler().sample(wallTimeNanoseconds: 123_456))

        #expect(sample.wallTimeNanoseconds == 123_456)
        #expect(sample.cpuTimeNanoseconds > 0)
        #expect(sample.physicalFootprintBytes > 0)
    }

    @Test func formatsPhysicalFootprintInMegabytesAndUnavailableState() {
        #expect(DiagnosticsHUDFormatter.physicalFootprint(176_160_768) == "168 MB")
        #expect(DiagnosticsHUDFormatter.physicalFootprint(nil) == "—")
    }

    @Test func calculatesAverageAndNearestRankP95() throws {
        #expect(DiagnosticsMath.durationStatistics([]) == nil)

        let single = try #require(DiagnosticsMath.durationStatistics([4.25]))
        #expect(single.averageMilliseconds == 4.25)
        #expect(single.p95Milliseconds == 4.25)

        let many = try #require(DiagnosticsMath.durationStatistics((1...20).map(Double.init)))
        #expect(many.averageMilliseconds == 10.5)
        #expect(many.p95Milliseconds == 19)
    }
}

@Suite struct DiagnosticsCaptureTests {
    @Test func classifiesAllScreenCaptureKitStatuses() {
        #expect(LiveThumbnailCoordinator.diagnosticsStatus(frameStatus: .started) == .started)
        #expect(LiveThumbnailCoordinator.diagnosticsStatus(frameStatus: .complete) == .complete)
        #expect(LiveThumbnailCoordinator.diagnosticsStatus(frameStatus: .idle) == .idle)
        #expect(LiveThumbnailCoordinator.diagnosticsStatus(frameStatus: .blank) == .blank)
        #expect(LiveThumbnailCoordinator.diagnosticsStatus(frameStatus: .suspended) == .suspended)
        #expect(LiveThumbnailCoordinator.diagnosticsStatus(frameStatus: .stopped) == .stopped)
    }

    @Test func statusCounterKeepsEachClassificationSeparate() {
        var counter = DiagnosticsStatusCounter()
        for status in DiagnosticsFrameStatus.allCases {
            counter.record(status)
        }
        #expect(counter.snapshot == DiagnosticsStatusCounts(
            started: 1,
            complete: 1,
            idle: 1,
            blank: 1,
            suspended: 1,
            stopped: 1
        ))
    }

    @Test func tracksCurrentAndMaximumPipelineBacklog() throws {
        let collector = CaptureDiagnostics()
        collector.prepareSummon(windowIDs: [1])
        let start = mach_absolute_time()
        collector.beginSession(windowLabels: [1: "Editor"], now: start)

        var timings: [DiagnosticsFrameTiming] = []
        for _ in 0..<3 {
            let timing = try #require(collector.recordFrame(
                windowID: 1,
                status: .complete,
                width: 100,
                height: 100,
                windowServerDisplayMachTime: nil
            ))
            collector.recordYielded(timing: timing)
            timings.append(timing)
        }
        collector.recordUIDelivery(timing: timings[0])
        collector.recordUIDelivery(timing: timings[1])

        let snapshot = try #require(collector.makeSnapshot(
            now: start + DiagnosticsMachClock.ticks(seconds: 1)
        ))
        #expect(snapshot.delivery.yieldedFrames == 3)
        #expect(snapshot.delivery.uiDeliveredFrames == 2)
        #expect(snapshot.delivery.currentBacklog == 1)
        #expect(snapshot.delivery.maximumBacklog == 3)
        #expect(snapshot.delivery.droppedOrCoalescedFrames == 0)
    }

    @Test func tracksPreConversionCoalescingWithoutChangingDeliveryBacklog() throws {
        let collector = CaptureDiagnostics()
        collector.prepareSummon(windowIDs: [1])
        let start = mach_absolute_time()
        collector.beginSession(windowLabels: [1: "Editor"], now: start)

        let timing = try #require(collector.recordFrame(
            windowID: 1,
            status: .complete,
            width: 100,
            height: 100,
            windowServerDisplayMachTime: nil
        ))
        collector.recordPreConversionCoalesced(timing: timing)

        let snapshot = try #require(collector.makeSnapshot(
            now: start + DiagnosticsMachClock.ticks(seconds: 1)
        ))
        #expect(snapshot.delivery.droppedOrCoalescedFrames == 1)
        #expect(snapshot.delivery.yieldedFrames == 0)
        #expect(snapshot.delivery.currentBacklog == 0)
    }

    @Test func replacingPendingFrameKeepsDeliveryBacklogBounded() throws {
        let collector = CaptureDiagnostics()
        collector.prepareSummon(windowIDs: [1])
        let start = mach_absolute_time()
        collector.beginSession(windowLabels: [1: "Editor"], now: start)

        let first = try #require(collector.recordFrame(
            windowID: 1,
            status: .complete,
            width: 100,
            height: 100,
            windowServerDisplayMachTime: nil
        ))
        collector.recordYielded(timing: first)
        let newest = try #require(collector.recordFrame(
            windowID: 1,
            status: .complete,
            width: 100,
            height: 100,
            windowServerDisplayMachTime: nil
        ))
        collector.recordYielded(timing: newest, replacing: first)

        let snapshot = try #require(collector.makeSnapshot(
            now: start + DiagnosticsMachClock.ticks(seconds: 1)
        ))
        #expect(snapshot.delivery.yieldedFrames == 1)
        #expect(snapshot.delivery.currentBacklog == 1)
        #expect(snapshot.delivery.maximumBacklog == 1)
        #expect(snapshot.delivery.droppedOrCoalescedFrames == 1)
    }

    @Test func selectsHighestBandwidthWindowOverLatestInterval() throws {
        let current: [CGWindowID: DiagnosticsWindowCounters] = [
            10: .init(frames: 20, pixels: 8_000_000),
            20: .init(frames: 12, pixels: 12_000_000),
        ]
        let previous: [CGWindowID: DiagnosticsWindowCounters] = [
            10: .init(frames: 10, pixels: 4_000_000),
            20: .init(frames: 10, pixels: 10_000_000),
        ]
        let top = try #require(DiagnosticsTopContributorSelector.select(
            current: current,
            previous: previous,
            labels: [10: "Editor", 20: "Browser"],
            elapsedSeconds: 0.5
        ))
        #expect(top.windowID == 10)
        #expect(top.label == "Editor")
        #expect(top.framesPerSecond == 20)
        #expect(top.megapixelsPerSecond == 8)
    }

    @Test func resetsAllSessionCountersBetweenSummons() throws {
        let collector = CaptureDiagnostics()
        let start = mach_absolute_time()
        collector.prepareSummon(windowIDs: [1])
        collector.beginSession(windowLabels: [1: "First"], now: start)
        _ = collector.recordFrame(
            windowID: 1,
            status: .complete,
            width: 100,
            height: 100,
            windowServerDisplayMachTime: nil
        )
        _ = collector.endSession(now: start + DiagnosticsMachClock.ticks(seconds: 1))

        let secondStart = mach_absolute_time()
        collector.prepareSummon(windowIDs: [2, 3])
        collector.beginSession(windowLabels: [2: "Second", 3: "Third"], now: secondStart)
        let reset = try #require(collector.makeSnapshot(
            now: secondStart + DiagnosticsMachClock.ticks(seconds: 1)
        ))
        #expect(reset.capture.requestedWindowCount == 2)
        #expect(reset.capture.changedFrames == 0)
        #expect(reset.conversion.framesEntered == 0)
        #expect(reset.delivery.yieldedFrames == 0)
        #expect(reset.delivery.maximumBacklog == 0)
        #expect(reset.topContributor == nil)
    }

    @Test func disabledRecordingIsANoOp() {
        let collector = CaptureDiagnostics()
        collector.prepareSummon(windowIDs: [1])
        let timing = collector.recordFrame(
            windowID: 1,
            status: .complete,
            width: 640,
            height: 400,
            windowServerDisplayMachTime: 1
        )
        #expect(timing == nil)
        #expect(!collector.isEnabled)
        #expect(collector.makeSnapshot() == nil)
    }

    @Test func staleCallbacksFromAnEndedSessionCannotContaminateTheNextSession() throws {
        let collector = CaptureDiagnostics()
        collector.prepareSummon(windowIDs: [1])
        let firstStart = mach_absolute_time()
        collector.beginSession(windowLabels: [1: "First"], now: firstStart)
        let oldTiming = try #require(collector.recordFrame(
            windowID: 1,
            status: .complete,
            width: 100,
            height: 50,
            windowServerDisplayMachTime: nil
        ))
        let oldConversion = try #require(collector.beginConversion(
            timing: oldTiming,
            now: firstStart
        ))
        _ = collector.endSession(
            now: firstStart + DiagnosticsMachClock.ticks(seconds: 1)
        )

        collector.prepareSummon(windowIDs: [2])
        let secondStart = mach_absolute_time()
        collector.beginSession(windowLabels: [2: "Second"], now: secondStart)
        collector.recordYielded(timing: oldTiming)
        collector.recordUIDelivery(
            timing: oldTiming,
            now: secondStart + DiagnosticsMachClock.ticks(seconds: 0.01)
        )
        collector.recordPreConversionCoalesced(timing: oldTiming)
        collector.endConversion(
            oldConversion,
            succeeded: true,
            convertedPixelCount: 5_000,
            now: secondStart + DiagnosticsMachClock.ticks(seconds: 0.01)
        )

        let snapshot = try #require(collector.makeSnapshot(
            now: secondStart + DiagnosticsMachClock.ticks(seconds: 1)
        ))
        #expect(snapshot.capture.requestedWindowCount == 1)
        #expect(snapshot.capture.changedFrames == 0)
        #expect(snapshot.conversion.framesEntered == 0)
        #expect(snapshot.conversion.successful == 0)
        #expect(snapshot.delivery.yieldedFrames == 0)
        #expect(snapshot.delivery.uiDeliveredFrames == 0)
        #expect(snapshot.delivery.droppedOrCoalescedFrames == 0)
        #expect(snapshot.latency.callbackArrivalToUIDelivery == nil)
    }

    @Test func assemblesConversionLatencyAndProcessPeaksIntoTheSnapshot() throws {
        let collector = CaptureDiagnostics()
        collector.prepareSummon(windowIDs: [1])
        let start = mach_absolute_time()
        collector.beginSession(windowLabels: [1: "Editor"], now: start)

        let sourceTime = mach_absolute_time()
        let successfulTiming = try #require(collector.recordFrame(
            windowID: 1,
            status: .complete,
            width: 200,
            height: 100,
            windowServerDisplayMachTime: sourceTime
        ))
        let successfulConversion = try #require(collector.beginConversion(
            timing: successfulTiming,
            now: start
        ))
        collector.endConversion(
            successfulConversion,
            succeeded: true,
            convertedPixelCount: 20_000,
            now: start + DiagnosticsMachClock.ticks(seconds: 0.004)
        )
        collector.recordYielded(timing: successfulTiming)
        collector.recordUIDelivery(
            timing: successfulTiming,
            now: successfulTiming.callbackArrivalMachTime
                + DiagnosticsMachClock.ticks(seconds: 0.01)
        )

        let failedTiming = try #require(collector.recordFrame(
            windowID: 1,
            status: .started,
            width: 200,
            height: 100,
            windowServerDisplayMachTime: nil
        ))
        let failedConversion = try #require(collector.beginConversion(
            timing: failedTiming,
            now: start
        ))
        collector.endConversion(
            failedConversion,
            succeeded: false,
            convertedPixelCount: 0,
            now: start + DiagnosticsMachClock.ticks(seconds: 0.006)
        )

        collector.recordProcessResources(
            currentCPUPercentage: 80,
            averageCPUPercentage: 80,
            physicalFootprintBytes: 500,
            packageIdleWakeupsPerSecond: 9
        )
        collector.recordProcessResources(
            currentCPUPercentage: 25,
            averageCPUPercentage: 30,
            physicalFootprintBytes: 100,
            packageIdleWakeupsPerSecond: 2
        )

        let snapshot = try #require(collector.makeSnapshot(
            now: start + DiagnosticsMachClock.ticks(seconds: 1)
        ))
        #expect(snapshot.conversion.framesEntered == 2)
        #expect(snapshot.conversion.successful == 1)
        #expect(snapshot.conversion.failed == 1)
        #expect(snapshot.conversion.convertedMegapixels == 0.02)
        #expect(snapshot.conversion.duration?.averageMilliseconds == 5)
        #expect(snapshot.conversion.duration?.p95Milliseconds == 6)
        #expect(abs((snapshot.latency.callbackArrivalToUIDelivery?.averageMilliseconds ?? 0) - 10) < 0.001)
        #expect(snapshot.latency.windowServerToUIDelivery != nil)
        #expect(snapshot.process.currentCPUPercentage == 25)
        #expect(snapshot.process.averageCPUPercentage == 30)
        #expect(snapshot.process.peakCPUPercentage == 80)
        #expect(snapshot.process.physicalFootprintBytes == 100)
        #expect(snapshot.process.peakPhysicalFootprintBytes == 500)
        #expect(snapshot.process.packageIdleWakeupsPerSecond == 2)
    }

    @Test func successiveSnapshotsReportRatesForOnlyTheLatestInterval() throws {
        let collector = CaptureDiagnostics()
        collector.prepareSummon(windowIDs: [1])
        let start = mach_absolute_time()
        collector.beginSession(windowLabels: [1: "Editor"], now: start)

        let first = try #require(collector.recordFrame(
            windowID: 1,
            status: .complete,
            width: 1_000,
            height: 1_000,
            windowServerDisplayMachTime: nil
        ))
        collector.recordYielded(timing: first)
        collector.recordUIDelivery(timing: first)
        let firstSnapshot = try #require(collector.makeSnapshot(
            now: start + DiagnosticsMachClock.ticks(seconds: 1)
        ))
        #expect(firstSnapshot.capture.changedFramesPerSecond == 1)
        #expect(firstSnapshot.capture.changedMegapixelsPerSecond == 1)
        #expect(firstSnapshot.delivery.yieldedFramesPerSecond == 1)
        #expect(firstSnapshot.delivery.uiDeliveredFramesPerSecond == 1)

        for _ in 0..<2 {
            let timing = try #require(collector.recordFrame(
                windowID: 1,
                status: .complete,
                width: 1_000,
                height: 1_000,
                windowServerDisplayMachTime: nil
            ))
            collector.recordYielded(timing: timing)
            collector.recordUIDelivery(timing: timing)
        }
        let secondSnapshot = try #require(collector.makeSnapshot(
            now: start + DiagnosticsMachClock.ticks(seconds: 3)
        ))
        #expect(secondSnapshot.capture.changedFrames == 3)
        #expect(secondSnapshot.capture.changedFramesPerSecond == 1)
        #expect(secondSnapshot.capture.changedMegapixelsPerSecond == 1)
        #expect(secondSnapshot.delivery.yieldedFrames == 3)
        #expect(secondSnapshot.delivery.yieldedFramesPerSecond == 1)
        #expect(secondSnapshot.delivery.uiDeliveredFramesPerSecond == 1)
    }

    @Test func enablingMidSummonKeepsDeduplicatedStartupCountsWithoutInventingLatency() throws {
        let collector = CaptureDiagnostics()
        collector.prepareSummon(windowIDs: [1, 2, 3])
        let startup = mach_absolute_time()
        let startupToken = collector.beginLiveStreamStartup(now: startup)
        collector.recordStreamStarted(windowID: 1)
        collector.recordStreamStarted(windowID: 1)
        collector.recordStreamStartupFailure(windowID: 2)
        collector.recordStreamStartupFailure(windowID: 2)
        collector.endLiveStreamStartup(startupToken)

        let sessionStart = mach_absolute_time()
        collector.beginSession(windowLabels: [1: "Editor"], now: sessionStart)
        _ = collector.recordFrame(
            windowID: 1,
            status: .complete,
            width: 100,
            height: 100,
            windowServerDisplayMachTime: nil
        )

        let snapshot = try #require(collector.makeSnapshot(
            now: sessionStart + DiagnosticsMachClock.ticks(seconds: 1)
        ))
        #expect(snapshot.capture.requestedWindowCount == 3)
        #expect(snapshot.capture.streamsStarted == 1)
        #expect(snapshot.capture.streamStartupFailures == 1)
        #expect(snapshot.capture.firstLiveFrameLatencyMilliseconds == nil)
    }
}

@Suite struct DiagnosticsHUDFormattingTests {
    @Test func unavailableOptionalMetricsUseStablePlaceholders() {
        let text = DiagnosticsHUDFormatter.text(for: emptySnapshot)
        #expect(text.contains("FIRST —"))
        #expect(text.contains("CPU —"))
        #expect(text.contains("MEM —"))
        #expect(text.contains("LAG   WS —  CB —"))
        #expect(text.contains("TOP  —"))
        #expect(!text.contains("presented"))

        let summary = DiagnosticsHUDFormatter.dismissalSummary(emptySnapshot)
        #expect(summary.contains("backlog 0/max 0, drops 0"))
    }

    @Test func availableMetricsAndContributorsAreRendered() {
        let snapshot = DiagnosticsSnapshot(
            sessionDurationSeconds: 3.5,
            capture: DiagnosticsCaptureSnapshot(
                requestedWindowCount: 3,
                streamsStarted: 2,
                streamStartupFailures: 1,
                statusCounts: .zero,
                statusRates: DiagnosticsStatusRates(
                    started: 1,
                    complete: 2,
                    idle: 3,
                    blank: 4,
                    suspended: 5,
                    stopped: 6
                ),
                changedFrames: 12,
                changedMegapixels: 4.5,
                changedFramesPerSecond: 6,
                changedMegapixelsPerSecond: 2.25,
                firstLiveFrameLatencyMilliseconds: 125
            ),
            conversion: DiagnosticsConversionSnapshot(
                framesEntered: 10,
                successful: 9,
                failed: 1,
                duration: DiagnosticsDurationStatistics(
                    averageMilliseconds: 2,
                    p95Milliseconds: 7
                ),
                convertedMegapixels: 4,
                convertedMegapixelsPerSecond: 2
            ),
            delivery: DiagnosticsDeliverySnapshot(
                yieldedFrames: 9,
                yieldedFramesPerSecond: 4.5,
                uiDeliveredFrames: 8,
                uiDeliveredFramesPerSecond: 4,
                currentBacklog: 1,
                maximumBacklog: 3,
                droppedOrCoalescedFrames: 2
            ),
            latency: DiagnosticsLatencySnapshot(
                windowServerToUIDelivery: DiagnosticsDurationStatistics(
                    averageMilliseconds: 8,
                    p95Milliseconds: 12
                ),
                callbackArrivalToUIDelivery: DiagnosticsDurationStatistics(
                    averageMilliseconds: 3,
                    p95Milliseconds: 5
                )
            ),
            topContributor: DiagnosticsTopContributor(
                windowID: 101,
                label: "A very long editor window label for truncation",
                framesPerSecond: 5,
                megapixelsPerSecond: 1.5
            ),
            sessionTopContributor: DiagnosticsTopContributor(
                windowID: 202,
                label: "Browser",
                framesPerSecond: 4,
                megapixelsPerSecond: 2
            ),
            process: DiagnosticsProcessSnapshot(
                currentCPUPercentage: 43,
                averageCPUPercentage: 25,
                peakCPUPercentage: 50,
                physicalFootprintBytes: 32 * 1_048_576,
                peakPhysicalFootprintBytes: 48 * 1_048_576,
                packageIdleWakeupsPerSecond: 3.5
            )
        )

        let text = DiagnosticsHUDFormatter.text(for: snapshot)
        #expect(text.contains("2/3 streams  FAIL 1  FIRST 125 ms  CPU 43%  MEM 32 MB"))
        #expect(text.contains("CONV  2.0/7.0 ms avg/p95"))
        #expect(text.contains("LAG   WS 8.0/12.0 ms avg/p95  CB 3.0/5.0 ms avg/p95"))
        #expect(text.contains("WAKE  3.5/s"))
        #expect(text.contains("A very long editor window l…"))
        #expect(!text.contains("A very long editor window label for truncation"))

        let summary = DiagnosticsHUDFormatter.dismissalSummary(snapshot)
        #expect(summary.contains("CPU avg 25%/peak 50%"))
        #expect(summary.contains("memory peak 48 MB"))
        #expect(summary.contains("top Browser 4.0 fps/2.0 MPix/s"))
    }

    private var emptySnapshot: DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            sessionDurationSeconds: 1,
            capture: DiagnosticsCaptureSnapshot(
                requestedWindowCount: 0,
                streamsStarted: 0,
                streamStartupFailures: 0,
                statusCounts: .zero,
                statusRates: .zero,
                changedFrames: 0,
                changedMegapixels: 0,
                changedFramesPerSecond: 0,
                changedMegapixelsPerSecond: 0,
                firstLiveFrameLatencyMilliseconds: nil
            ),
            conversion: DiagnosticsConversionSnapshot(
                framesEntered: 0,
                successful: 0,
                failed: 0,
                duration: nil,
                convertedMegapixels: 0,
                convertedMegapixelsPerSecond: 0
            ),
            delivery: DiagnosticsDeliverySnapshot(
                yieldedFrames: 0,
                yieldedFramesPerSecond: 0,
                uiDeliveredFrames: 0,
                uiDeliveredFramesPerSecond: 0,
                currentBacklog: 0,
                maximumBacklog: 0,
                droppedOrCoalescedFrames: 0
            ),
            latency: DiagnosticsLatencySnapshot(
                windowServerToUIDelivery: nil,
                callbackArrivalToUIDelivery: nil
            ),
            topContributor: nil,
            sessionTopContributor: nil,
            process: .unavailable
        )
    }
}

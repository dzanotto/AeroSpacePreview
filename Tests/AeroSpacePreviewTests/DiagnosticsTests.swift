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
        #expect(CaptureService.diagnosticsStatus(frameStatus: .started) == .started)
        #expect(CaptureService.diagnosticsStatus(frameStatus: .complete) == .complete)
        #expect(CaptureService.diagnosticsStatus(frameStatus: .idle) == .idle)
        #expect(CaptureService.diagnosticsStatus(frameStatus: .blank) == .blank)
        #expect(CaptureService.diagnosticsStatus(frameStatus: .suspended) == .suspended)
        #expect(CaptureService.diagnosticsStatus(frameStatus: .stopped) == .stopped)
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

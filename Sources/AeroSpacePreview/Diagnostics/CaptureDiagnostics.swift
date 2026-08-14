import CoreGraphics
import Darwin
import os

struct DiagnosticsFrameTiming: Sendable {
    let generation: UInt64
    let callbackArrivalMachTime: UInt64
    let windowServerDisplayMachTime: UInt64?
}

struct DiagnosticsConversionToken: @unchecked Sendable {
    let generation: UInt64
    let startMachTime: UInt64
    let signpostState: OSSignpostIntervalState?
}

struct DiagnosticsStartupToken: @unchecked Sendable {
    let signpostState: OSSignpostIntervalState?
}

struct DiagnosticsWindowCounters: Equatable, Sendable {
    var frames: UInt64 = 0
    var pixels: UInt64 = 0
}

enum DiagnosticsTopContributorSelector {
    static func select(
        current: [CGWindowID: DiagnosticsWindowCounters],
        previous: [CGWindowID: DiagnosticsWindowCounters],
        labels: [CGWindowID: String],
        elapsedSeconds: Double
    ) -> DiagnosticsTopContributor? {
        guard elapsedSeconds > 0 else { return nil }
        let contribution = current.compactMap { windowID, counters -> (CGWindowID, UInt64, UInt64)? in
            let prior = previous[windowID] ?? DiagnosticsWindowCounters()
            guard counters.frames >= prior.frames, counters.pixels >= prior.pixels else { return nil }
            let frames = counters.frames - prior.frames
            let pixels = counters.pixels - prior.pixels
            guard frames > 0 else { return nil }
            return (windowID, frames, pixels)
        }.max { lhs, rhs in
            if lhs.2 == rhs.2 { return lhs.1 < rhs.1 }
            return lhs.2 < rhs.2
        }
        guard let contribution else { return nil }
        return DiagnosticsTopContributor(
            windowID: contribution.0,
            label: labels[contribution.0] ?? "Window \(contribution.0)",
            framesPerSecond: Double(contribution.1) / elapsedSeconds,
            megapixelsPerSecond: Double(contribution.2) / 1_000_000 / elapsedSeconds
        )
    }
}

struct DiagnosticsStatusCounter: Equatable, Sendable {
    private(set) var started: UInt64 = 0
    private(set) var complete: UInt64 = 0
    private(set) var idle: UInt64 = 0
    private(set) var blank: UInt64 = 0
    private(set) var suspended: UInt64 = 0
    private(set) var stopped: UInt64 = 0

    mutating func record(_ status: DiagnosticsFrameStatus) {
        switch status {
        case .started: started += 1
        case .complete: complete += 1
        case .idle: idle += 1
        case .blank: blank += 1
        case .suspended: suspended += 1
        case .stopped: stopped += 1
        }
    }

    var snapshot: DiagnosticsStatusCounts {
        DiagnosticsStatusCounts(
            started: started,
            complete: complete,
            idle: idle,
            blank: blank,
            suspended: suspended,
            stopped: stopped
        )
    }

    func rates(since previous: DiagnosticsStatusCounter, elapsedSeconds: Double) -> DiagnosticsStatusRates {
        DiagnosticsStatusRates(
            started: DiagnosticsMath.rate(delta: started - previous.started, elapsedSeconds: elapsedSeconds),
            complete: DiagnosticsMath.rate(delta: complete - previous.complete, elapsedSeconds: elapsedSeconds),
            idle: DiagnosticsMath.rate(delta: idle - previous.idle, elapsedSeconds: elapsedSeconds),
            blank: DiagnosticsMath.rate(delta: blank - previous.blank, elapsedSeconds: elapsedSeconds),
            suspended: DiagnosticsMath.rate(delta: suspended - previous.suspended, elapsedSeconds: elapsedSeconds),
            stopped: DiagnosticsMath.rate(delta: stopped - previous.stopped, elapsedSeconds: elapsedSeconds)
        )
    }
}

/// Hot-path diagnostics for all per-window callback queues. The only work done
/// while disabled is one unfair-lock check; no timestamps, signposts, samples,
/// allocations, tasks, or actor hops are created per frame.
final class CaptureDiagnostics: @unchecked Sendable {
    private static let signposter = OSSignposter(
        subsystem: "com.dariozanotto.aerospacepreview",
        category: "Diagnostics"
    )
    private let lockedState = OSAllocatedUnfairLock(initialState: State())

    var isEnabled: Bool {
        lockedState.withLock { $0.session != nil }
    }

    /// Establishes sparse startup bookkeeping for the current summon even if
    /// diagnostics are enabled later from the menu.
    func prepareSummon(windowIDs: [CGWindowID]) {
        lockedState.withLock { state in
            state.summon = SummonState(requestedWindowCount: windowIDs.count)
        }
    }

    func beginSession(
        windowLabels: [CGWindowID: String],
        now: UInt64 = mach_absolute_time()
    ) {
        lockedState.withLock { state in
            state.nextGeneration += 1
            var session = SessionState(
                generation: state.nextGeneration,
                startMachTime: now,
                labels: windowLabels
            )
            // If streams are already active, enabling mid-summon cannot
            // reconstruct the true first-frame latency, so leave it absent.
            if state.summon.startedWindowIDs.isEmpty {
                session.liveStartupMachTime = state.summon.liveStartupMachTime
            }
            state.session = session
        }
    }

    func endSession(now: UInt64 = mach_absolute_time()) -> DiagnosticsSnapshot? {
        lockedState.withLock { state in
            guard state.session != nil else { return nil }
            let snapshot = Self.makeSnapshot(state: &state, now: now)
            state.session = nil
            return snapshot
        }
    }

    func makeSnapshot(now: UInt64 = mach_absolute_time()) -> DiagnosticsSnapshot? {
        lockedState.withLock { state in
            Self.makeSnapshot(state: &state, now: now)
        }
    }

    func beginLiveStreamStartup(now: UInt64 = mach_absolute_time()) -> DiagnosticsStartupToken {
        let enabled = lockedState.withLock { state in
            state.summon.liveStartupMachTime = now
            state.session?.liveStartupMachTime = now
            return state.session != nil
        }
        let interval: OSSignpostIntervalState?
        if enabled {
            let id = Self.signposter.makeSignpostID()
            interval = Self.signposter.beginInterval("Live stream startup", id: id)
        } else {
            interval = nil
        }
        return DiagnosticsStartupToken(signpostState: interval)
    }

    func endLiveStreamStartup(_ token: DiagnosticsStartupToken) {
        if let interval = token.signpostState {
            Self.signposter.endInterval("Live stream startup", interval)
        }
    }

    func recordStreamStarted(windowID: CGWindowID) {
        _ = lockedState.withLock { state in
            state.summon.startedWindowIDs.insert(windowID)
        }
    }

    func recordStreamStartupFailure(windowID: CGWindowID) {
        let enabled = lockedState.withLock { state in
            state.summon.startupFailureWindowIDs.insert(windowID)
            return state.session != nil
        }
        if enabled {
            Self.signposter.emitEvent("Stream start failure", "window \(windowID)")
        }
    }

    func recordFrame(
        windowID: CGWindowID,
        status: DiagnosticsFrameStatus,
        width: Int?,
        height: Int?,
        windowServerDisplayMachTime: @autoclosure () -> UInt64?
    ) -> DiagnosticsFrameTiming? {
        // Unchecked is safe here: the autoclosure is evaluated synchronously
        // under the lock and never escapes to another concurrency domain.
        lockedState.withLockUnchecked { state in
            guard state.session != nil else { return nil }
            let callbackArrival = mach_absolute_time()
            state.session!.statuses.record(status)

            let isChanged = status == .started || status == .complete
            if isChanged {
                state.session!.changedFrames += 1
                var contribution = state.session!.windowContributions[windowID]
                    ?? DiagnosticsWindowCounters()
                contribution.frames += 1
                if let width, let height, width > 0, height > 0 {
                    let pixels = UInt64(width) * UInt64(height)
                    state.session!.changedPixels += pixels
                    contribution.pixels += pixels
                }
                state.session!.windowContributions[windowID] = contribution
                if state.session!.firstLiveFrameLatencyMilliseconds == nil,
                   let startup = state.session!.liveStartupMachTime {
                    state.session!.firstLiveFrameLatencyMilliseconds = DiagnosticsMachClock.milliseconds(
                        from: startup,
                        to: callbackArrival
                    )
                }
            }

            guard isChanged, width != nil, height != nil else { return nil }
            return DiagnosticsFrameTiming(
                generation: state.session!.generation,
                callbackArrivalMachTime: callbackArrival,
                windowServerDisplayMachTime: windowServerDisplayMachTime()
            )
        }
    }

    func beginConversion(
        timing: DiagnosticsFrameTiming,
        now: UInt64? = nil
    ) -> DiagnosticsConversionToken? {
        let enabled = lockedState.withLock { state in
            guard state.session?.generation == timing.generation else { return false }
            state.session!.conversionsEntered += 1
            return true
        }
        guard enabled else { return nil }
        let id = Self.signposter.makeSignpostID()
        let interval = Self.signposter.beginInterval("CGImage conversion", id: id)
        return DiagnosticsConversionToken(
            generation: timing.generation,
            // Capture after the signpost call so collector overhead is not
            // included in the createCGImage duration distribution.
            startMachTime: now ?? mach_absolute_time(),
            signpostState: interval
        )
    }

    func endConversion(
        _ token: DiagnosticsConversionToken,
        succeeded: Bool,
        convertedPixelCount: UInt64,
        now: UInt64 = mach_absolute_time()
    ) {
        if let interval = token.signpostState {
            Self.signposter.endInterval("CGImage conversion", interval)
        }
        guard let milliseconds = DiagnosticsMachClock.milliseconds(from: token.startMachTime, to: now) else {
            return
        }
        lockedState.withLock { state in
            guard state.session?.generation == token.generation else { return }
            state.session!.conversionDurations.append(milliseconds)
            if succeeded {
                state.session!.successfulConversions += 1
                state.session!.convertedPixels += convertedPixelCount
            } else {
                state.session!.failedConversions += 1
            }
        }
    }

    /// Reserves backlog before yielding so a concurrently resumed consumer
    /// cannot temporarily make consumed exceed yielded.
    func recordYielded(timing: DiagnosticsFrameTiming) {
        recordYielded(timing: timing, replacing: nil)
    }

    /// Atomically accounts for a newly pending frame and the older pending
    /// frame it replaces, keeping measured backlog aligned with the keyed
    /// delivery buffer's actual bound.
    func recordYielded(
        timing: DiagnosticsFrameTiming?,
        replacing replacedTiming: DiagnosticsFrameTiming?
    ) {
        lockedState.withLock { state in
            guard state.session != nil else { return }
            if let replacedTiming,
               state.session!.generation == replacedTiming.generation {
                if state.session!.yieldedFrames > state.session!.uiDeliveredFrames {
                    state.session!.yieldedFrames -= 1
                }
                state.session!.droppedOrCoalescedFrames += 1
            }
            if let timing, state.session!.generation == timing.generation {
                state.session!.yieldedFrames += 1
            }
            let backlog = state.session!.yieldedFrames - min(
                state.session!.yieldedFrames,
                state.session!.uiDeliveredFrames
            )
            state.session!.maximumBacklog = max(state.session!.maximumBacklog, backlog)
        }
    }

    func recordYieldRejected(timing: DiagnosticsFrameTiming, droppedOrCoalesced: Bool) {
        lockedState.withLock { state in
            guard state.session?.generation == timing.generation else { return }
            if state.session!.yieldedFrames > 0 { state.session!.yieldedFrames -= 1 }
            if droppedOrCoalesced { state.session!.droppedOrCoalescedFrames += 1 }
        }
    }

    func recordPreConversionCoalesced(timing: DiagnosticsFrameTiming?) {
        guard let timing else { return }
        lockedState.withLock { state in
            guard state.session?.generation == timing.generation else { return }
            state.session!.droppedOrCoalescedFrames += 1
        }
    }

    func recordUIDelivery(
        timing: DiagnosticsFrameTiming?,
        now: UInt64 = mach_absolute_time()
    ) {
        guard let timing else { return }
        lockedState.withLock { state in
            guard state.session?.generation == timing.generation else { return }
            state.session!.uiDeliveredFrames += 1
            if let callbackLatency = DiagnosticsMachClock.milliseconds(
                from: timing.callbackArrivalMachTime,
                to: now
            ) {
                state.session!.callbackLatencies.append(callbackLatency)
            }
            if let sourceTime = timing.windowServerDisplayMachTime,
               sourceTime > 0,
               let sourceLatency = DiagnosticsMachClock.milliseconds(from: sourceTime, to: now) {
                state.session!.sourceLatencies.append(sourceLatency)
            }
        }
    }

    func recordProcessResources(
        currentCPUPercentage: Double,
        averageCPUPercentage: Double,
        physicalFootprintBytes: UInt64,
        packageIdleWakeupsPerSecond: Double
    ) {
        lockedState.withLock { state in
            guard var session = state.session else { return }
            session.currentCPUPercentage = currentCPUPercentage
            session.averageCPUPercentage = averageCPUPercentage
            session.peakCPUPercentage = max(session.peakCPUPercentage ?? 0, currentCPUPercentage)
            session.physicalFootprintBytes = physicalFootprintBytes
            session.peakPhysicalFootprintBytes = max(
                session.peakPhysicalFootprintBytes ?? 0,
                physicalFootprintBytes
            )
            session.packageIdleWakeupsPerSecond = packageIdleWakeupsPerSecond
            state.session = session
        }
    }

    private static func makeSnapshot(state: inout State, now: UInt64) -> DiagnosticsSnapshot? {
        guard var session = state.session,
              let intervalSeconds = DiagnosticsMachClock.seconds(
                from: session.lastSnapshotMachTime,
                to: now
              ),
              let sessionSeconds = DiagnosticsMachClock.seconds(
                from: session.startMachTime,
                to: now
              )
        else { return nil }

        let previous = session.previousCounters
        let statusRates = session.statuses.rates(
            since: previous.statuses,
            elapsedSeconds: intervalSeconds
        )
        let top = DiagnosticsTopContributorSelector.select(
            current: session.windowContributions,
            previous: session.previousWindowContributions,
            labels: session.labels,
            elapsedSeconds: intervalSeconds
        )
        let sessionTop = DiagnosticsTopContributorSelector.select(
            current: session.windowContributions,
            previous: [:],
            labels: session.labels,
            elapsedSeconds: sessionSeconds
        )
        let currentBacklog = session.yieldedFrames - min(
            session.yieldedFrames,
            session.uiDeliveredFrames
        )
        let snapshot = DiagnosticsSnapshot(
            sessionDurationSeconds: sessionSeconds,
            capture: DiagnosticsCaptureSnapshot(
                requestedWindowCount: state.summon.requestedWindowCount,
                streamsStarted: state.summon.startedWindowIDs.count,
                streamStartupFailures: state.summon.startupFailureWindowIDs.count,
                statusCounts: session.statuses.snapshot,
                statusRates: statusRates,
                changedFrames: session.changedFrames,
                changedMegapixels: Double(session.changedPixels) / 1_000_000,
                changedFramesPerSecond: DiagnosticsMath.rate(
                    delta: session.changedFrames - previous.changedFrames,
                    elapsedSeconds: intervalSeconds
                ),
                changedMegapixelsPerSecond: DiagnosticsMath.rate(
                    delta: session.changedPixels - previous.changedPixels,
                    elapsedSeconds: intervalSeconds
                ) / 1_000_000,
                firstLiveFrameLatencyMilliseconds: session.firstLiveFrameLatencyMilliseconds
            ),
            conversion: DiagnosticsConversionSnapshot(
                framesEntered: session.conversionsEntered,
                successful: session.successfulConversions,
                failed: session.failedConversions,
                duration: DiagnosticsMath.durationStatistics(session.conversionDurations.values),
                convertedMegapixels: Double(session.convertedPixels) / 1_000_000,
                convertedMegapixelsPerSecond: DiagnosticsMath.rate(
                    delta: session.convertedPixels - previous.convertedPixels,
                    elapsedSeconds: intervalSeconds
                ) / 1_000_000
            ),
            delivery: DiagnosticsDeliverySnapshot(
                yieldedFrames: session.yieldedFrames,
                yieldedFramesPerSecond: DiagnosticsMath.rate(
                    delta: session.yieldedFrames - min(session.yieldedFrames, previous.yieldedFrames),
                    elapsedSeconds: intervalSeconds
                ),
                uiDeliveredFrames: session.uiDeliveredFrames,
                uiDeliveredFramesPerSecond: DiagnosticsMath.rate(
                    delta: session.uiDeliveredFrames - min(session.uiDeliveredFrames, previous.uiDeliveredFrames),
                    elapsedSeconds: intervalSeconds
                ),
                currentBacklog: currentBacklog,
                maximumBacklog: session.maximumBacklog,
                droppedOrCoalescedFrames: session.droppedOrCoalescedFrames
            ),
            latency: DiagnosticsLatencySnapshot(
                windowServerToUIDelivery: DiagnosticsMath.durationStatistics(session.sourceLatencies.values),
                callbackArrivalToUIDelivery: DiagnosticsMath.durationStatistics(session.callbackLatencies.values)
            ),
            topContributor: top,
            sessionTopContributor: sessionTop,
            process: DiagnosticsProcessSnapshot(
                currentCPUPercentage: session.currentCPUPercentage,
                averageCPUPercentage: session.averageCPUPercentage,
                peakCPUPercentage: session.peakCPUPercentage,
                physicalFootprintBytes: session.physicalFootprintBytes,
                peakPhysicalFootprintBytes: session.peakPhysicalFootprintBytes,
                packageIdleWakeupsPerSecond: session.packageIdleWakeupsPerSecond
            )
        )

        session.lastSnapshotMachTime = now
        session.previousCounters = SnapshotCounters(session)
        session.previousWindowContributions = session.windowContributions
        state.session = session
        return snapshot
    }
}

private struct State: Sendable {
    var nextGeneration: UInt64 = 0
    var summon = SummonState()
    var session: SessionState?
}

private struct SummonState: Sendable {
    var requestedWindowCount = 0
    var startedWindowIDs: Set<CGWindowID> = []
    var startupFailureWindowIDs: Set<CGWindowID> = []
    var liveStartupMachTime: UInt64?
}

private struct SnapshotCounters: Sendable {
    var statuses = DiagnosticsStatusCounter()
    var changedFrames: UInt64 = 0
    var changedPixels: UInt64 = 0
    var convertedPixels: UInt64 = 0
    var yieldedFrames: UInt64 = 0
    var uiDeliveredFrames: UInt64 = 0

    init() {}

    init(_ session: SessionState) {
        statuses = session.statuses
        changedFrames = session.changedFrames
        changedPixels = session.changedPixels
        convertedPixels = session.convertedPixels
        yieldedFrames = session.yieldedFrames
        uiDeliveredFrames = session.uiDeliveredFrames
    }
}

private struct SessionState: Sendable {
    let generation: UInt64
    let startMachTime: UInt64
    var lastSnapshotMachTime: UInt64
    let labels: [CGWindowID: String]
    var liveStartupMachTime: UInt64?
    var firstLiveFrameLatencyMilliseconds: Double?

    var statuses = DiagnosticsStatusCounter()
    var changedFrames: UInt64 = 0
    var changedPixels: UInt64 = 0
    var conversionsEntered: UInt64 = 0
    var successfulConversions: UInt64 = 0
    var failedConversions: UInt64 = 0
    var convertedPixels: UInt64 = 0
    var yieldedFrames: UInt64 = 0
    var uiDeliveredFrames: UInt64 = 0
    var maximumBacklog: UInt64 = 0
    var droppedOrCoalescedFrames: UInt64 = 0

    var conversionDurations = FixedDurationBuffer(capacity: 256)
    var sourceLatencies = FixedDurationBuffer(capacity: 256)
    var callbackLatencies = FixedDurationBuffer(capacity: 256)
    var windowContributions: [CGWindowID: DiagnosticsWindowCounters] = [:]
    var previousWindowContributions: [CGWindowID: DiagnosticsWindowCounters] = [:]
    var previousCounters = SnapshotCounters()

    var currentCPUPercentage: Double?
    var averageCPUPercentage: Double?
    var peakCPUPercentage: Double?
    var physicalFootprintBytes: UInt64?
    var peakPhysicalFootprintBytes: UInt64?
    var packageIdleWakeupsPerSecond: Double?

    init(generation: UInt64, startMachTime: UInt64, labels: [CGWindowID: String]) {
        self.generation = generation
        self.startMachTime = startMachTime
        lastSnapshotMachTime = startMachTime
        self.labels = labels
    }
}

private struct FixedDurationBuffer: Sendable {
    let capacity: Int
    private(set) var values: [Double] = []
    private var nextIndex = 0

    init(capacity: Int) {
        self.capacity = capacity
        values.reserveCapacity(capacity)
    }

    mutating func append(_ value: Double) {
        guard value.isFinite, value >= 0, capacity > 0 else { return }
        if values.count < capacity {
            values.append(value)
        } else {
            values[nextIndex] = value
            nextIndex = (nextIndex + 1) % capacity
        }
    }
}

enum DiagnosticsMachClock {
    private static let timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()

    static func seconds(from start: UInt64, to end: UInt64) -> Double? {
        guard end >= start else { return nil }
        let ticks = Double(end - start)
        let nanoseconds = ticks * Double(timebase.numer) / Double(timebase.denom)
        return nanoseconds / 1_000_000_000
    }

    static func milliseconds(from start: UInt64, to end: UInt64) -> Double? {
        seconds(from: start, to: end).map { $0 * 1_000 }
    }

    static func ticks(seconds: Double) -> UInt64 {
        UInt64(seconds * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
    }
}

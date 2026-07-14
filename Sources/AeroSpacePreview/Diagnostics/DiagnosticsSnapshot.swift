import Foundation

enum DiagnosticsFrameStatus: CaseIterable, Sendable {
    case started
    case complete
    case idle
    case blank
    case suspended
    case stopped
}

struct DiagnosticsStatusCounts: Equatable, Sendable {
    let started: UInt64
    let complete: UInt64
    let idle: UInt64
    let blank: UInt64
    let suspended: UInt64
    let stopped: UInt64

    static let zero = DiagnosticsStatusCounts(
        started: 0,
        complete: 0,
        idle: 0,
        blank: 0,
        suspended: 0,
        stopped: 0
    )
}

struct DiagnosticsStatusRates: Equatable, Sendable {
    let started: Double
    let complete: Double
    let idle: Double
    let blank: Double
    let suspended: Double
    let stopped: Double

    static let zero = DiagnosticsStatusRates(
        started: 0,
        complete: 0,
        idle: 0,
        blank: 0,
        suspended: 0,
        stopped: 0
    )
}

struct DiagnosticsDurationStatistics: Equatable, Sendable {
    let averageMilliseconds: Double
    let p95Milliseconds: Double
}

struct DiagnosticsCaptureSnapshot: Equatable, Sendable {
    let requestedWindowCount: Int
    let streamsStarted: Int
    let streamStartupFailures: Int
    let statusCounts: DiagnosticsStatusCounts
    let statusRates: DiagnosticsStatusRates
    let changedFrames: UInt64
    let changedMegapixels: Double
    let changedFramesPerSecond: Double
    let changedMegapixelsPerSecond: Double
    let firstLiveFrameLatencyMilliseconds: Double?
}

struct DiagnosticsConversionSnapshot: Equatable, Sendable {
    let framesEntered: UInt64
    let successful: UInt64
    let failed: UInt64
    let duration: DiagnosticsDurationStatistics?
    let convertedMegapixels: Double
    let convertedMegapixelsPerSecond: Double
}

struct DiagnosticsDeliverySnapshot: Equatable, Sendable {
    let yieldedFrames: UInt64
    let yieldedFramesPerSecond: Double
    let uiDeliveredFrames: UInt64
    let uiDeliveredFramesPerSecond: Double
    let currentBacklog: UInt64
    let maximumBacklog: UInt64
    let droppedOrCoalescedFrames: UInt64
}

struct DiagnosticsLatencySnapshot: Equatable, Sendable {
    let windowServerToUIDelivery: DiagnosticsDurationStatistics?
    let callbackArrivalToUIDelivery: DiagnosticsDurationStatistics?
}

struct DiagnosticsTopContributor: Equatable, Sendable {
    let windowID: UInt32
    let label: String
    let framesPerSecond: Double
    let megapixelsPerSecond: Double
}

struct DiagnosticsProcessSnapshot: Equatable, Sendable {
    let currentCPUPercentage: Double?
    let averageCPUPercentage: Double?
    let peakCPUPercentage: Double?
    let physicalFootprintBytes: UInt64?
    let peakPhysicalFootprintBytes: UInt64?
    let packageIdleWakeupsPerSecond: Double?

    static let unavailable = DiagnosticsProcessSnapshot(
        currentCPUPercentage: nil,
        averageCPUPercentage: nil,
        peakCPUPercentage: nil,
        physicalFootprintBytes: nil,
        peakPhysicalFootprintBytes: nil,
        packageIdleWakeupsPerSecond: nil
    )
}

/// Immutable, 2 Hz view of one enabled overlay diagnostics session.
struct DiagnosticsSnapshot: Equatable, Sendable {
    let sessionDurationSeconds: Double
    let capture: DiagnosticsCaptureSnapshot
    let conversion: DiagnosticsConversionSnapshot
    let delivery: DiagnosticsDeliverySnapshot
    let latency: DiagnosticsLatencySnapshot
    let topContributor: DiagnosticsTopContributor?
    let sessionTopContributor: DiagnosticsTopContributor?
    let process: DiagnosticsProcessSnapshot
}

enum DiagnosticsMath {
    static func rate(delta: UInt64, elapsedSeconds: Double) -> Double {
        guard elapsedSeconds > 0 else { return 0 }
        return Double(delta) / elapsedSeconds
    }

    static func durationStatistics(_ samples: [Double]) -> DiagnosticsDurationStatistics? {
        guard !samples.isEmpty else { return nil }
        let average = samples.reduce(0, +) / Double(samples.count)
        let sorted = samples.sorted()
        let index = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return DiagnosticsDurationStatistics(
            averageMilliseconds: average,
            p95Milliseconds: sorted[index]
        )
    }
}

/// Pure formatting used by both the SwiftUI panel and deterministic tests.
enum DiagnosticsHUDFormatter {
    static func physicalFootprint(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    static func text(for snapshot: DiagnosticsSnapshot) -> String {
        let capture = snapshot.capture
        let conversion = snapshot.conversion
        let delivery = snapshot.delivery
        let process = snapshot.process
        let first = milliseconds(capture.firstLiveFrameLatencyMilliseconds)
        let cpu = percentage(process.currentCPUPercentage)
        let memory = physicalFootprint(process.physicalFootprintBytes)
        let conversionTiming = durationPair(conversion.duration)
        let sourceLag = durationPair(snapshot.latency.windowServerToUIDelivery)
        let callbackLag = durationPair(snapshot.latency.callbackArrivalToUIDelivery)
        let wakeups = process.packageIdleWakeupsPerSecond.map { String(format: "%.1f/s", $0) } ?? "—"
        let top = snapshot.topContributor.map {
            "\(concise($0.label)) · \(String(format: "%.1f", $0.framesPerSecond)) fps / "
                + "\(String(format: "%.1f", $0.megapixelsPerSecond)) MPix/s"
        } ?? "—"
        let rates = capture.statusRates

        return [
            "LIVE  \(capture.streamsStarted)/\(capture.requestedWindowCount) streams  FAIL \(capture.streamStartupFailures)  FIRST \(first)  CPU \(cpu)  MEM \(memory)",
            String(format: "INPUT %.1f fps / %.1f MPix/s", capture.changedFramesPerSecond, capture.changedMegapixelsPerSecond),
            String(format: "UI    %.1f fps  BACKLOG %llu / MAX %llu  DROP %llu", delivery.uiDeliveredFramesPerSecond, delivery.currentBacklog, delivery.maximumBacklog, delivery.droppedOrCoalescedFrames),
            String(format: "CONV  %@  FAIL %llu / %llu  %.1f MPix/s", conversionTiming, conversion.failed, conversion.framesEntered, conversion.convertedMegapixelsPerSecond),
            "LAG   WS \(sourceLag)  CB \(callbackLag)",
            String(format: "STAT  S %.1f  C %.1f  I %.1f  B %.1f  SU %.1f  ST %.1f fps", rates.started, rates.complete, rates.idle, rates.blank, rates.suspended, rates.stopped),
            "WAKE  \(wakeups)  TOP  \(top)",
        ].joined(separator: "\n")
    }

    static func dismissalSummary(_ snapshot: DiagnosticsSnapshot) -> String {
        let capture = snapshot.capture
        let delivery = snapshot.delivery
        let top = snapshot.sessionTopContributor.map {
            "\($0.label) \(String(format: "%.1f", $0.framesPerSecond)) fps/\(String(format: "%.1f", $0.megapixelsPerSecond)) MPix/s"
        } ?? "n/a"
        return String(
            format: "AeroSpacePreview: diagnostics — %.1f s; streams %d/%d, failures %d; input %llu frames/%.1f MPix; UI %llu; backlog %llu/max %llu, drops %llu; conversion %@; pipeline lag %@; CPU avg %@/peak %@; memory peak %@; top %@",
            snapshot.sessionDurationSeconds,
            capture.streamsStarted,
            capture.requestedWindowCount,
            capture.streamStartupFailures,
            capture.changedFrames,
            capture.changedMegapixels,
            delivery.uiDeliveredFrames,
            delivery.currentBacklog,
            delivery.maximumBacklog,
            delivery.droppedOrCoalescedFrames,
            durationPair(snapshot.conversion.duration),
            durationPair(
                snapshot.latency.windowServerToUIDelivery
                    ?? snapshot.latency.callbackArrivalToUIDelivery
            ),
            percentage(snapshot.process.averageCPUPercentage),
            percentage(snapshot.process.peakCPUPercentage),
            physicalFootprint(snapshot.process.peakPhysicalFootprintBytes),
            top
        )
    }

    private static func durationPair(_ statistics: DiagnosticsDurationStatistics?) -> String {
        guard let statistics else { return "—" }
        return String(
            format: "%.1f/%.1f ms avg/p95",
            statistics.averageMilliseconds,
            statistics.p95Milliseconds
        )
    }

    private static func milliseconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f ms", value)
    }

    private static func percentage(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value)
    }

    private static func concise(_ label: String) -> String {
        label.count <= 28 ? label : String(label.prefix(27)) + "…"
    }
}

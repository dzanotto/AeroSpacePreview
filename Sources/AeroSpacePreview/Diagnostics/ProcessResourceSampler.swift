import Darwin
import Foundation

struct ProcessResourceSample: Equatable, Sendable {
    let wallTimeNanoseconds: UInt64
    let cpuTimeNanoseconds: UInt64
    let physicalFootprintBytes: UInt64
    let packageIdleWakeups: UInt64
}

struct ProcessResourceDelta: Equatable, Sendable {
    let cpuPercentage: Double
    let packageIdleWakeupsPerSecond: Double
}

enum ProcessResourceMath {
    static func delta(
        from previous: ProcessResourceSample,
        to current: ProcessResourceSample
    ) -> ProcessResourceDelta? {
        guard current.wallTimeNanoseconds > previous.wallTimeNanoseconds,
              current.cpuTimeNanoseconds >= previous.cpuTimeNanoseconds,
              current.packageIdleWakeups >= previous.packageIdleWakeups
        else { return nil }

        let elapsedNanoseconds = current.wallTimeNanoseconds - previous.wallTimeNanoseconds
        let elapsedSeconds = Double(elapsedNanoseconds) / 1_000_000_000
        let cpuDelta = current.cpuTimeNanoseconds - previous.cpuTimeNanoseconds
        let wakeupDelta = current.packageIdleWakeups - previous.packageIdleWakeups
        return ProcessResourceDelta(
            // Activity Monitor semantics: 100% is one fully occupied core.
            cpuPercentage: Double(cpuDelta) / Double(elapsedNanoseconds) * 100,
            packageIdleWakeupsPerSecond: Double(wakeupDelta) / elapsedSeconds
        )
    }
}

/// Lightweight public-process accounting. A read failure simply produces no
/// resource fields in the next diagnostics snapshot.
struct ProcessResourceSampler: Sendable {
    func sample(wallTimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) -> ProcessResourceSample? {
        var usage = rusage_info_v0()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V0, $0)
            }
        }
        guard result == 0 else { return nil }
        return ProcessResourceSample(
            wallTimeNanoseconds: wallTimeNanoseconds,
            cpuTimeNanoseconds: usage.ri_user_time &+ usage.ri_system_time,
            physicalFootprintBytes: usage.ri_phys_footprint,
            packageIdleWakeups: usage.ri_pkg_idle_wkups
        )
    }
}

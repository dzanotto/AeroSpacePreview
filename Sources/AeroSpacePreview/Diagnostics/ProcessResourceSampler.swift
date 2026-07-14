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
    static func nanoseconds(
        fromMachTicks ticks: UInt64,
        numerator: UInt32,
        denominator: UInt32
    ) -> UInt64? {
        guard denominator > 0 else { return nil }

        let numerator = UInt64(numerator)
        let denominator = UInt64(denominator)
        let quotient = ticks / denominator
        let remainder = ticks % denominator
        let wholeNanoseconds = quotient.multipliedReportingOverflow(by: numerator)
        guard !wholeNanoseconds.overflow else { return nil }

        let fractionalNanoseconds = remainder * numerator / denominator
        let total = wholeNanoseconds.partialValue.addingReportingOverflow(fractionalNanoseconds)
        return total.overflow ? nil : total.partialValue
    }

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
    private static let timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()

    func sample(wallTimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) -> ProcessResourceSample? {
        var usage = rusage_info_v0()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V0, $0)
            }
        }
        let cpuTicks = usage.ri_user_time.addingReportingOverflow(usage.ri_system_time)
        guard result == 0,
              !cpuTicks.overflow,
              // CPU usage fields are Mach absolute-time ticks, not nanoseconds.
              let cpuTimeNanoseconds = ProcessResourceMath.nanoseconds(
                  fromMachTicks: cpuTicks.partialValue,
                  numerator: Self.timebase.numer,
                  denominator: Self.timebase.denom
              )
        else { return nil }

        return ProcessResourceSample(
            wallTimeNanoseconds: wallTimeNanoseconds,
            cpuTimeNanoseconds: cpuTimeNanoseconds,
            physicalFootprintBytes: usage.ri_phys_footprint,
            packageIdleWakeups: usage.ri_pkg_idle_wkups
        )
    }
}

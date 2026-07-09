import Darwin
import Foundation

struct ProcessUsage: Identifiable {
    let name: String
    let cpuFraction: Double
    var id: String { name }
}

/// Ranks processes by CPU via libproc rusage deltas between ticks.
/// Helper processes are grouped under their owning .app bundle, the way
/// the system battery menu groups "Using Significant Energy" entries.
final class ProcessSampler {
    private var previousCPUTime: [pid_t: UInt64] = [:]
    private var previousSampleTime: UInt64 = 0
    private let coreCount = Double(ProcessInfo.processInfo.activeProcessorCount)
    private let timebase: (numer: Double, denom: Double) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (Double(tb.numer), Double(tb.denom))
    }()

    /// Returns the top `count` process groups by CPU, as a fraction of
    /// total machine capacity (same scale as CPUSampler). Empty on the
    /// first call — no delta baseline yet.
    func sample(top count: Int = 3) -> [ProcessUsage] {
        let now = mach_absolute_time()
        var pids = [pid_t](repeating: 0, count: 8192)
        let listed = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard listed > 0 else { return [] }

        var currentCPUTime: [pid_t: UInt64] = [:]
        var groupFractions: [String: Double] = [:]
        let wallNanos = (Double(now - previousSampleTime)) * timebase.numer / timebase.denom
        let hadBaseline = previousSampleTime > 0 && wallNanos > 0

        for pid in pids[0..<Int(listed)] where pid > 0 {
            var info = rusage_info_current()
            let ok = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            guard ok == 0 else { continue }
            let cpuNanos = UInt64((Double(info.ri_user_time + info.ri_system_time)) * timebase.numer / timebase.denom)
            currentCPUTime[pid] = cpuNanos

            guard hadBaseline, let previous = previousCPUTime[pid], cpuNanos > previous else { continue }
            let fraction = Double(cpuNanos - previous) / wallNanos / coreCount
            guard fraction > 0.0005, let name = displayName(for: pid) else { continue }
            groupFractions[name, default: 0] += fraction
        }

        previousCPUTime = currentCPUTime
        previousSampleTime = now

        return groupFractions
            .sorted { $0.value > $1.value }
            .prefix(count)
            .map { ProcessUsage(name: $0.key, cpuFraction: $0.value) }
    }

    /// App bundle name when the executable lives inside one ("Claude"),
    /// otherwise the executable name ("WindowServer").
    private func displayName(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        if let appComponent = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) {
            return String(appComponent.dropLast(4))
        }
        return (path as NSString).lastPathComponent
    }
}

import Darwin
import Foundation

struct ProcessEntry: Identifiable {
    let name: String
    /// CPU fraction of total machine capacity, or memory bytes,
    /// depending on which ranking this entry came from.
    let value: Double
    var id: String { name }
}

/// Ranks processes by CPU (rusage deltas between ticks) and by memory
/// (physical footprint, Activity Monitor's "Memory" column). Helper
/// processes are grouped under their owning .app bundle, the way the
/// system battery menu groups "Using Significant Energy" entries.
final class ProcessSampler {
    private var previousCPUTime: [pid_t: UInt64] = [:]
    private var previousSampleTime: UInt64 = 0
    private let coreCount = Double(ProcessInfo.processInfo.activeProcessorCount)
    private let timebase: (numer: Double, denom: Double) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (Double(tb.numer), Double(tb.denom))
    }()

    /// CPU ranking is empty on the first call (no delta baseline yet);
    /// the memory ranking is available immediately.
    func sample(top count: Int = 3) -> (cpu: [ProcessEntry], memory: [ProcessEntry]) {
        let now = mach_absolute_time()
        var pids = [pid_t](repeating: 0, count: 8192)
        let listed = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard listed > 0 else { return ([], []) }

        var currentCPUTime: [pid_t: UInt64] = [:]
        var cpuByGroup: [String: Double] = [:]
        var memoryByGroup: [String: Double] = [:]
        var nameCache: [pid_t: String] = [:]
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

            func cachedName() -> String? {
                if let name = nameCache[pid] { return name }
                guard let name = displayName(for: pid) else { return nil }
                nameCache[pid] = name
                return name
            }

            if info.ri_phys_footprint > 0, let name = cachedName() {
                memoryByGroup[name, default: 0] += Double(info.ri_phys_footprint)
            }

            let cpuNanos = UInt64((Double(info.ri_user_time + info.ri_system_time)) * timebase.numer / timebase.denom)
            currentCPUTime[pid] = cpuNanos
            if hadBaseline, let previous = previousCPUTime[pid], cpuNanos > previous {
                let fraction = Double(cpuNanos - previous) / wallNanos / coreCount
                if fraction > 0.0005, let name = cachedName() {
                    cpuByGroup[name, default: 0] += fraction
                }
            }
        }

        previousCPUTime = currentCPUTime
        previousSampleTime = now

        func top3(_ groups: [String: Double]) -> [ProcessEntry] {
            groups.sorted { $0.value > $1.value }
                .prefix(count)
                .map { ProcessEntry(name: $0.key, value: $0.value) }
        }
        return (top3(cpuByGroup), top3(memoryByGroup))
    }

    /// App bundle name when the executable lives inside one ("Claude"),
    /// otherwise the executable name ("WindowServer").
    private func displayName(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
        if let appComponent = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) {
            return String(appComponent.dropLast(4))
        }
        return (path as NSString).lastPathComponent
    }
}

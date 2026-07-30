import Darwin
import Foundation

struct ProcessEntry: Identifiable, Sendable {
    let name: String
    /// CPU fraction of total machine capacity, or memory bytes,
    /// depending on which ranking this entry came from.
    let value: Double
    /// Every pid folded into this group, so a client can quit the whole
    /// app rather than a single helper.
    let pids: [pid_t]
    /// Whether every pid in the group runs as this user — i.e. whether the
    /// deliberately-unprivileged kill/restart control could actually act on
    /// it. False for root daemons (kernel_task, mds_stores…), whose kill
    /// would only ever come back `denied`.
    let owned: Bool
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
        // Enumerate via sysctl KERN_PROC_ALL — the door ps uses — NOT
        // proc_listallpids. On macOS 26 (verified 26.5.2 on BOTH Macs,
        // 2026-07-30) proc_listallpids silently returns only a newest-first
        // TAIL of the process table: Air 223 of 894, mini 164 of 673, cut at
        // a hard pid threshold regardless of owner. Anything long-running —
        // Finder, login items, a boot-time OrbStack VM holding 12 GB — was
        // never enumerated at all, which read as "quiet machine" rather than
        // a broken sampler. The sysctl door returns the whole table
        // unprivileged on the same machines.
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return ([], []) }
        // Headroom: processes spawned between the size probe and the fetch.
        size += 64 * MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return ([], []) }
        let listed = size / MemoryLayout<kinfo_proc>.stride
        let pids = procs[0..<listed].map { $0.kp_proc.p_pid }

        var currentCPUTime: [pid_t: UInt64] = [:]
        var cpuByGroup: [String: Double] = [:]
        var memoryByGroup: [String: Double] = [:]
        var maxResidentByGroup: [String: Double] = [:]
        var nameCache: [pid_t: String] = [:]
        // One map shared by both rankings: a pid joins on FIRST name lookup
        // from either pass, so a per-ranking map could hand back a partial
        // pid list and "quit this app" would strand its helpers.
        var pidsByGroup: [String: [pid_t]] = [:]
        let wallNanos = (Double(now - previousSampleTime)) * timebase.numer / timebase.denom
        let hadBaseline = previousSampleTime > 0 && wallNanos > 0

        for pid in pids where pid > 0 {
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
                pidsByGroup[name, default: []].append(pid)
                return name
            }

            if info.ri_phys_footprint > 0, let name = cachedName() {
                memoryByGroup[name, default: 0] += Double(info.ri_phys_footprint)
            }
            // Track the group's single largest resident set alongside the
            // footprint sum — see the group-level max below.
            if info.ri_resident_size > 0, let name = cachedName() {
                maxResidentByGroup[name] = max(maxResidentByGroup[name] ?? 0, Double(info.ri_resident_size))
            }

            let cpuNanos = UInt64((Double(info.ri_user_time + info.ri_system_time)) * timebase.numer / timebase.denom)
            currentCPUTime[pid] = cpuNanos
            // No minimum threshold: an idle many-core Mac can have NOTHING
            // above any fixed floor (worse at longer refresh intervals, which
            // average spikes away), and an empty CPU list reads as a broken
            // app rather than a quiet machine. Accumulating every positive
            // delta costs nothing extra — the memory pass above already
            // resolves names for effectively every pid — and top-N picks the
            // honest winners either way.
            if hadBaseline, let previous = previousCPUTime[pid], cpuNanos > previous {
                let fraction = Double(cpuNanos - previous) / wallNanos / coreCount
                if fraction > 0, let name = cachedName() {
                    cpuByGroup[name, default: 0] += fraction
                }
            }
        }

        previousCPUTime = currentCPUTime
        previousSampleTime = now

        // A group's memory is the LARGER of its summed footprint and its
        // single biggest process's resident set. Footprint (Activity
        // Monitor's column) is the honest default — it excludes shared
        // pages, so an app's helpers don't multiply-count what they map in
        // common (ranking per-pid resident inflated Chrome ~3× here). But
        // that same exclusion made a long-running OrbStack VM invisible:
        // its guest RAM lives in SHARED regions (mac-mini, 2026-07-30 —
        // helper at 11.8 GB resident, 665 MB footprint, absent from this
        // list while dominating machine-wide used; a freshly booted VM's
        // memory is anonymous and footprint-counted, which is why the Air
        // couldn't reproduce it). One process's own resident set can't
        // double-count its siblings, so the group max surfaces VM-style
        // processes while ordinary apps — whose helpers' summed footprint
        // dwarfs any single resident set — keep their Activity Monitor
        // numbers.
        for (name, resident) in maxResidentByGroup where resident > memoryByGroup[name] ?? 0 {
            memoryByGroup[name] = resident
        }

        func top3(_ groups: [String: Double]) -> [ProcessEntry] {
            groups.sorted { $0.value > $1.value }
                .prefix(count)
                .map {
                    let pids = pidsByGroup[$0.key] ?? []
                    return ProcessEntry(
                        name: $0.key, value: $0.value, pids: pids,
                        owned: Self.owned(pids: pids)
                    )
                }
        }
        return (top3(cpuByGroup), top3(memoryByGroup))
    }

    /// True when every pid in the group runs as this user. Checked only for
    /// the top-N groups (a handful of syscalls), never the whole table. A pid
    /// that vanished before the check counts as not-owned — conservative, and
    /// a kill on it would be refused by the pid-reuse interlock anyway.
    private static func owned(pids: [pid_t]) -> Bool {
        let uid = geteuid()
        for pid in pids {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_uid == uid
            else { return false }
        }
        return true
    }

    private func displayName(for pid: pid_t) -> String? {
        Self.displayName(for: pid)
    }

    /// App bundle name when the executable lives inside one ("Claude"),
    /// otherwise the executable name ("WindowServer").
    ///
    /// Static and shared with `Control`'s pid-reuse interlock on purpose: the
    /// interlock compares a pid's *current* name against the name the client
    /// saw, so both sides must derive names identically or valid kills would
    /// be rejected (and, worse, the check could pass on the wrong process).
    static func displayName(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
        if let appComponent = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) {
            return String(appComponent.dropLast(4))
        }
        return (path as NSString).lastPathComponent
    }
}

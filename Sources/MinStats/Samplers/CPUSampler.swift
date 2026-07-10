import Darwin

/// Reads total CPU utilization via host_processor_info.
final class CPUSampler {
    private var previousBusy: UInt64 = 0
    private var previousIdle: UInt64 = 0
    private var hasBaseline = false

    init() {}

    /// Total CPU usage as a fraction 0...1 across all cores.
    /// Returns nil on the first call (no delta available yet).
    func sample() -> Double? {
        var numCPUs: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }

        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        var busy: UInt64 = 0
        var idle: UInt64 = 0
        for cpu in 0..<Int(numCPUs) {
            let base = cpu * Int(CPU_STATE_MAX)
            busy += UInt64(info[base + Int(CPU_STATE_USER)])
                + UInt64(info[base + Int(CPU_STATE_SYSTEM)])
                + UInt64(info[base + Int(CPU_STATE_NICE)])
            idle += UInt64(info[base + Int(CPU_STATE_IDLE)])
        }

        defer {
            previousBusy = busy
            previousIdle = idle
            hasBaseline = true
        }

        guard hasBaseline else { return nil }

        let deltaBusy = busy >= previousBusy ? busy - previousBusy : 0
        let deltaIdle = idle >= previousIdle ? idle - previousIdle : 0
        let total = deltaBusy + deltaIdle
        guard total > 0 else { return nil }

        return Double(deltaBusy) / Double(total)
    }
}

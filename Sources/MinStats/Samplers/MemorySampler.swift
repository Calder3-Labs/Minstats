import Darwin
import Foundation

struct MemoryStats {
    let usedGB: Double
    let totalGB: Double
}

/// Reads system memory usage via host_statistics64, matching
/// Activity Monitor's "Memory Used" figure.
final class MemorySampler {
    init() {}

    func sample() -> MemoryStats? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        let internalPages = Int64(stats.internal_page_count)
        let purgeablePages = Int64(stats.purgeable_count)
        let wiredPages = Int64(stats.wire_count)
        let compressedPages = Int64(stats.compressor_page_count)
        let usedPages = max(0, internalPages - purgeablePages + wiredPages + compressedPages)
        let usedBytes = UInt64(usedPages) * UInt64(pageSize)

        let usedGB = Double(usedBytes) / 1_073_741_824
        let totalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824

        return MemoryStats(usedGB: usedGB, totalGB: totalGB)
    }
}

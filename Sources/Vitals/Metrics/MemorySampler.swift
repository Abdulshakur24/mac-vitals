import Darwin
import Foundation

struct MemorySample: Equatable {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var active: UInt64 = 0
    var inactive: UInt64 = 0
    var compressed: UInt64 = 0
    var free: UInt64 = 0
    /// 1 = normal, 2 = warning, 4 = critical (kernel's own scale).
    var pressureLevel: Int32 = 1
    /// 0...1, the number Activity Monitor draws as its pressure graph.
    var pressure: Double = 0

    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

/// System-wide memory statistics from the Mach VM subsystem.
final class MemorySampler {
    private let pageSize: UInt64 = {
        var size: vm_size_t = 0
        host_page_size(mach_host_self(), &size)
        return UInt64(size)
    }()

    private let totalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory

    func sample() -> MemorySample? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let wired = UInt64(stats.wire_count) * pageSize
        let active = UInt64(stats.active_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let free = UInt64(stats.free_count) * pageSize

        // Activity Monitor's "App Memory" is internal (anonymous) pages minus
        // the purgeable ones the kernel can drop on demand. Using `active`
        // here instead is the common shortcut, but it drifts from the number
        // shown in Activity Monitor by a few hundred MB.
        let purgeable = UInt64(stats.purgeable_count) * pageSize
        let internalPages = UInt64(stats.internal_page_count) * pageSize
        let app = internalPages > purgeable ? internalPages - purgeable : 0

        // "Memory Used" = app + wired + compressed. Inactive and speculative
        // pages are reclaimable, so they are deliberately excluded.
        let used = app + wired + compressed

        let level = pressureLevel()

        return MemorySample(
            total: totalMemory,
            used: used,
            app: app,
            wired: wired,
            active: active,
            inactive: inactive,
            compressed: compressed,
            free: free,
            pressureLevel: level,
            // Wired and compressed pages are the ones that can't be evicted
            // cheaply, so their share of total is the honest pressure signal.
            pressure: totalMemory > 0 ? Double(wired + compressed) / Double(totalMemory) : 0
        )
    }

    private func pressureLevel() -> Int32 {
        var value: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else {
            return 1
        }
        return value
    }
}

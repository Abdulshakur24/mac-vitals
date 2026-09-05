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
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    /// 1 = normal, 2 = warning, 4 = critical (kernel's own scale).
    var pressureLevel: Int32 = 1
    /// Share of physical RAM occupied by wired and compressed pages.
    /// This is not the system memory pressure measurement.
    var wiredAndCompressedFraction: Double = 0

    var pressureLabel: String {
        switch pressureLevel {
        case 4...: "Critical"
        case 2...: "Elevated"
        case 1: "Normal"
        default: "Unavailable"
        }
    }

    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    var swapFraction: Double { swapTotal > 0 ? Double(swapUsed) / Double(swapTotal) : 0 }
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
        let swap = swapUsage()

        return MemorySample(
            total: totalMemory,
            used: used,
            app: app,
            wired: wired,
            active: active,
            inactive: inactive,
            compressed: compressed,
            free: free,
            swapUsed: swap.used,
            swapTotal: swap.total,
            pressureLevel: level,
            // Explicit component ratio, separate from the kernel pressure level.
            wiredAndCompressedFraction: totalMemory > 0 ? Double(wired + compressed) / Double(totalMemory) : 0
        )
    }

    /// Size of the swap files on disk, and how much of them holds live pages.
    ///
    /// `swapTotal` is not a ceiling the way `total` is for physical memory —
    /// macOS grows and shrinks the swap files on demand, so the total is
    /// itself a measurement, and a machine that is swapping hard reports both
    /// numbers climbing together. Used alone is the signal; the pair is the
    /// context for it.
    private func swapUsage() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    private func pressureLevel() -> Int32 {
        var value: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else {
            return 0
        }
        return value
    }
}

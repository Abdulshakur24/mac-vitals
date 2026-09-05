import Darwin
import Foundation

struct CPUSample: Equatable {
    /// 0...1 across the whole machine.
    var total: Double = 0
    var user: Double = 0
    var system: Double = 0
    var nice: Double = 0
    /// Per-logical-core load, 0...1, in kernel core order.
    var perCore: [Double] = []

    var idle: Double { max(0, 1 - total) }
}

/// Per-core CPU load from the Mach host's tick counters.
///
/// The kernel hands back monotonically increasing tick counts, so load is the
/// delta between two samples divided by the total ticks elapsed. That makes the
/// result independent of how much wall time actually passed, which matters
/// because our timer runs with a large tolerance and fires irregularly.
final class CPUSampler {
    private struct Ticks {
        var user: UInt32 = 0
        var system: UInt32 = 0
        var idle: UInt32 = 0
        var nice: UInt32 = 0
    }

    private var previous: [Ticks] = []

    /// Split point between performance and efficiency cores on Apple Silicon.
    /// The kernel reports P-cores first, so counts are enough to label them.
    let performanceCoreCount: Int
    let efficiencyCoreCount: Int

    init() {
        performanceCoreCount = Self.sysctlInt("hw.perflevel0.logicalcpu") ?? 0
        efficiencyCoreCount = Self.sysctlInt("hw.perflevel1.logicalcpu") ?? 0
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    func resetBaseline() { previous = [] }

    func sample() -> CPUSample? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &info,
            &infoCount
        )
        guard result == KERN_SUCCESS, let info else { return nil }

        // host_processor_info allocates into our address space on every call.
        // Without this the process leaks a few KB per sample, which over a
        // day of 2s sampling is very visible.
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }

        var current: [Ticks] = []
        current.reserveCapacity(Int(cpuCount))
        for core in 0..<Int(cpuCount) {
            let base = core * Int(CPU_STATE_MAX)
            current.append(Ticks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            ))
        }

        defer { previous = current }

        // First call has no baseline to diff against.
        guard previous.count == current.count, !previous.isEmpty else { return nil }

        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)
        var userTicks = 0.0, systemTicks = 0.0, niceTicks = 0.0, allTicks = 0.0

        for (old, new) in zip(previous, current) {
            // Tick counters are UInt32 and do wrap on long uptimes; &- gives
            // the correct delta across the wrap instead of a huge bogus value.
            let dUser = Double(new.user &- old.user)
            let dSystem = Double(new.system &- old.system)
            let dIdle = Double(new.idle &- old.idle)
            let dNice = Double(new.nice &- old.nice)
            let dTotal = dUser + dSystem + dIdle + dNice

            perCore.append(dTotal > 0 ? (dUser + dSystem + dNice) / dTotal : 0)

            userTicks += dUser
            systemTicks += dSystem
            niceTicks += dNice
            allTicks += dTotal
        }

        guard allTicks > 0 else { return nil }

        return CPUSample(
            total: (userTicks + systemTicks + niceTicks) / allTicks,
            user: userTicks / allTicks,
            system: systemTicks / allTicks,
            nice: niceTicks / allTicks,
            perCore: perCore
        )
    }
}

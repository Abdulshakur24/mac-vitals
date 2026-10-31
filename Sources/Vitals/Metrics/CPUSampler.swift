import Darwin
import Foundation
import IOKit

/// Which logical cores are which kind.
///
/// Read from the device tree rather than inferred from counts, because the
/// kernel's order is not a given: on an M4 cpu0–5 are efficiency cores and
/// cpu6–9 are performance cores, so splitting by a count puts the wrong label
/// on most of the bars.
struct CoreLayout: Equatable {
    struct Group: Equatable {
        /// "P" or "E", or nil when the kinds could not be established.
        var label: String?
        var indices: [Int]
    }

    /// Performance cores first, then efficiency. A single unlabelled group
    /// when anything is unknown: an honest row of bars beats a wrong label.
    var groups: [Group]

    /// `kinds` maps a logical core id to its `cluster-type`.
    init(kinds: [Int: String], coreCount: Int) {
        let known = (0..<coreCount).compactMap { index in kinds[index].map { (index, $0) } }
        let performance = known.filter { $0.1 == "P" }.map(\.0)
        let efficiency = known.filter { $0.1 == "E" }.map(\.0)
        guard performance.count + efficiency.count == coreCount, coreCount > 0 else {
            groups = [Group(label: nil, indices: Array(0..<max(coreCount, 0)))]
            return
        }
        groups = [Group(label: "P", indices: performance), Group(label: "E", indices: efficiency)]
            .filter { !$0.indices.isEmpty }
    }

    func count(_ label: String) -> Int {
        groups.first { $0.label == label }?.indices.count ?? 0
    }

    /// Logical core id to `cluster-type`, from the `cpus` node of the device
    /// tree. Empty when the node is missing or shaped differently.
    static func readKinds() -> [Int: String] {
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard root != 0 else { return [:] }
        defer { IOObjectRelease(root) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(root, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }

        var kinds: [Int: String] = [:]
        while case let core = IOIteratorNext(iterator), core != 0 {
            defer { IOObjectRelease(core) }
            func property(_ name: String) -> Any? {
                IORegistryEntryCreateCFProperty(core, name as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue()
            }
            // Surfaced as a number on an M4. The device tree itself stores raw
            // little-endian bytes, so that form is accepted too.
            let id = property("logical-cpu-id")
            let index = (id as? NSNumber)?.intValue
                ?? (id as? Data).map { $0.prefix(4).reversed().reduce(0) { $0 << 8 | Int($1) } }
            guard let index, let type = property("cluster-type") as? Data else { continue }
            kinds[index] = String(decoding: type.prefix { $0 != 0 }, as: UTF8.self)
        }
        return kinds
    }
}

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

    /// Fixed for the life of the machine, so read once.
    let coreLayout = CoreLayout(kinds: CoreLayout.readKinds(),
                                coreCount: ProcessInfo.processInfo.processorCount)

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

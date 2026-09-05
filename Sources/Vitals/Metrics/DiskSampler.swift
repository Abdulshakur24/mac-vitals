import Foundation
import IOKit

struct DiskSample: Equatable {
    var read: Double = 0    // bytes/sec
    var write: Double = 0   // bytes/sec
    var free: UInt64 = 0
    var total: UInt64 = 0

    var usedFraction: Double {
        total > 0 ? Double(total > free ? total - free : 0) / Double(total) : 0
    }
    var freeFraction: Double {
        total > 0 ? Double(free) / Double(total) : 0
    }
}

/// Disk throughput from IOKit's block storage statistics, plus capacity.
///
/// Throughput and capacity are sampled on different schedules: byte counters
/// are cheap to read every tick, but free space requires a filesystem stat
/// that is both slower and effectively static, so it runs once a minute.
final class DiskSampler {
    private var previousRead: UInt64 = 0
    private var previousWrite: UInt64 = 0
    private var previousTime: TimeInterval = 0

    private var cachedFree: UInt64 = 0
    private var cachedTotal: UInt64 = 0
    private var lastCapacityCheck: TimeInterval = 0
    private let capacityInterval: TimeInterval = 60

    func resetBaseline() { previousTime = 0 }

    func sample() -> DiskSample? {
        let now = ProcessInfo.processInfo.systemUptime
        refreshCapacityIfNeeded(now: now)

        guard let (read, write) = counters() else { return nil }

        defer {
            previousRead = read
            previousWrite = write
            previousTime = now
        }

        guard previousTime > 0 else { return nil }
        let elapsed = now - previousTime
        guard elapsed > 0 else { return nil }

        return DiskSample(
            read: Double(read >= previousRead ? read - previousRead : 0) / elapsed,
            write: Double(write >= previousWrite ? write - previousWrite : 0) / elapsed,
            free: cachedFree,
            total: cachedTotal
        )
    }

    /// Sums the lifetime byte counters across every block storage driver.
    private func counters() -> (read: UInt64, write: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var write: UInt64 = 0

        while case let drive = IOIteratorNext(iterator), drive != 0 {
            defer { IOObjectRelease(drive) }

            guard let properties = IORegistryEntryCreateCFProperty(
                drive,
                "Statistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] else { continue }

            read += (properties["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (properties["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }

        return (read, write)
    }

    private func refreshCapacityIfNeeded(now: TimeInterval) {
        guard cachedTotal == 0 || now - lastCapacityCheck >= capacityInterval else { return }
        lastCapacityCheck = now

        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ]) else { return }

        // "ImportantUsage" is what Finder reports as available: it counts
        // purgeable caches the system would evict for a real allocation, so
        // it reads higher than `df` and matches what the user sees.
        if let available = values.volumeAvailableCapacityForImportantUsage {
            cachedFree = UInt64(max(0, available))
        }
        if let total = values.volumeTotalCapacity {
            cachedTotal = UInt64(max(0, total))
        }
    }
}

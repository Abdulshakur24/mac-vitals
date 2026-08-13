import Foundation

/// Fixed-capacity history buffer backing the sparklines.
///
/// Overwrites oldest samples in place so a long-running app never grows its
/// allocation. `values` returns oldest-to-newest, which is the order the
/// sparkline renderer draws in.
struct RingBuffer: Equatable {
    private var storage: [Double]
    private var next = 0
    private(set) var count = 0

    init(capacity: Int) {
        storage = Array(repeating: 0, count: max(1, capacity))
    }

    var capacity: Int { storage.count }

    mutating func append(_ value: Double) {
        storage[next] = value
        next = (next + 1) % storage.count
        if count < storage.count { count += 1 }
    }

    /// Oldest sample first.
    var values: [Double] {
        guard count > 0 else { return [] }
        if count < storage.count {
            return Array(storage[0..<count])
        }
        return Array(storage[next...]) + Array(storage[..<next])
    }

    var last: Double? { count > 0 ? storage[(next + storage.count - 1) % storage.count] : nil }

    var maximum: Double { values.max() ?? 0 }
}

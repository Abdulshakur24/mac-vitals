import Foundation

struct HistoryPoint: Equatable {
    var time: TimeInterval
    var value: Double
    var startsSegment: Bool
}

enum HistoryWindow: TimeInterval, CaseIterable, Identifiable {
    case fiveMinutes = 300
    case oneHour = 3600
    var id: Double { rawValue }
    var label: String { self == .fiveMinutes ? "5 min" : "1 hour" }
}

/// One hour of five-second peak buckets. Fixed storage bounds both memory and
/// chart work; timestamps keep the duration honest when polling slows down.
struct MetricHistory: Equatable {
    private var storage = [HistoryPoint?](repeating: nil, count: 721)
    private var next = 0
    private var count = 0
    private var needsSegment = true
    private var lastSample: TimeInterval?

    mutating func markGap() { needsSegment = true }

    mutating func append(_ value: Double, at time: TimeInterval, interval: TimeInterval) {
        guard value.isFinite, time.isFinite else { markGap(); return }
        let gap = needsSegment || lastSample.map { time <= $0 || time - $0 > max(10, interval * 2) } == true
        let index = (next + storage.count - 1) % storage.count
        if !gap, var point = storage[index], floor(point.time / 5) == floor(time / 5) {
            point.value = max(point.value, value)
            point.time = time
            storage[index] = point
        } else {
            storage[next] = HistoryPoint(time: time, value: value, startsSegment: gap)
            next = (next + 1) % storage.count
            count = min(count + 1, storage.count)
        }
        lastSample = time
        needsSegment = false
    }

    func points(endingAt end: TimeInterval, duration: TimeInterval) -> [HistoryPoint] {
        let start = (next + storage.count - count) % storage.count
        return (0..<count).compactMap { offset in
            guard let point = storage[(start + offset) % storage.count],
                  point.time >= end - duration, point.time <= end else { return nil }
            return point
        }
    }
}

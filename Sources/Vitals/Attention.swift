import Foundation

enum AttentionKind: String, CaseIterable, Codable {
    case disk, memory, thermal, cpu
}

struct AttentionEvent: Equatable, Identifiable, Codable {
    var id: UUID = UUID()
    var kind: AttentionKind
    var title: String
    var detail: String
    var startedAt: TimeInterval
    var endedAt: TimeInterval?
    /// Closed because sampling stopped, not because the condition cleared.
    /// Optional, like anything added here: a required key would make every
    /// existing history file fail to decode.
    var interrupted: Bool?
}

/// Local warning history. No notifications, process scans, or extra timer.
struct AttentionTracker {
    private var pending: [AttentionKind: TimeInterval] = [:]
    private(set) var events: [AttentionEvent] = []

    mutating func restore(_ history: [AttentionEvent]) {
        pending.removeAll()
        events = history
    }

    mutating func interrupt(at time: TimeInterval) {
        pending.removeAll()
        for index in events.indices where events[index].endedAt == nil {
            events[index].endedAt = time
            events[index].interrupted = true
        }
    }

    /// How long a stop in sampling can last and still be the same event.
    /// Short, so a duration never quietly spans an afternoon of something else.
    private static let reopenWindow: TimeInterval = 300

    /// The event a returning condition continues, if any.
    ///
    /// Without this every display sleep ends a warning and the wake starts it
    /// again, which fills the list with copies. Low disk space is reopened
    /// across any gap: it does not clear by itself while the Mac sleeps.
    private func interruptedEvent(of kind: AttentionKind, at time: TimeInterval) -> Int? {
        events.lastIndex { event in
            guard event.kind == kind, event.interrupted == true, let ended = event.endedAt else { return false }
            return kind == .disk || time - ended <= Self.reopenWindow
        }
    }

    mutating func update(snapshot: Snapshot, thresholds: Config.Thresholds, at time: TimeInterval) {
        var conditions: [AttentionKind: (String, String, TimeInterval)] = [:]
        if snapshot.disk.total > 0, snapshot.disk.freeFraction < thresholds.diskFree {
            conditions[.disk] = ("Disk space is low", "\(Format.bytes(snapshot.disk.free)) available · below \(Format.percent(thresholds.diskFree))", 0)
        }
        if snapshot.memory.total > 0, snapshot.memory.pressureLevel >= 2 {
            conditions[.memory] = ("Memory pressure is \(snapshot.memory.pressureLabel.lowercased())", "\(Format.bytes(snapshot.memory.swapUsed)) swap in use", snapshot.memory.pressureLevel >= 4 ? 0 : 10)
        }
        if snapshot.thermal.state == .serious || snapshot.thermal.state == .critical {
            conditions[.thermal] = ("Thermal state is \(snapshot.thermal.state == .critical ? "critical" : "serious")", "Reported by macOS", 0)
        }
        if !snapshot.cpu.perCore.isEmpty, snapshot.cpu.total >= thresholds.cpu {
            conditions[.cpu] = ("CPU use remains high", "\(Format.percent(snapshot.cpu.total)) overall · at or above \(Format.percent(thresholds.cpu))", 15)
        }
        for kind in AttentionKind.allCases {
            guard let (title, detail, delay) = conditions[kind] else {
                pending[kind] = nil
                for index in events.indices where events[index].kind == kind && events[index].endedAt == nil {
                    events[index].endedAt = time
                }
                continue
            }
            if pending[kind] == nil { pending[kind] = time }
            guard time - (pending[kind] ?? time) >= delay else { continue }
            if let index = events.firstIndex(where: { $0.kind == kind && $0.endedAt == nil }) {
                events[index].title = title
                events[index].detail = detail
            } else if let index = interruptedEvent(of: kind, at: time) {
                events[index].title = title
                events[index].detail = detail
                events[index].endedAt = nil
                events[index].interrupted = nil
            } else {
                events.append(AttentionEvent(kind: kind, title: title, detail: detail, startedAt: pending[kind] ?? time))
            }
        }
        events.removeAll { ($0.endedAt ?? time) < time - 3600 }
        if events.count > 20 {
            // Preserve ongoing conditions; discard the oldest completed events first.
            while events.count > 20, let index = events.firstIndex(where: { $0.endedAt != nil }) {
                events.remove(at: index)
            }
        }
    }
}

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
    /// What was using the resource when the warning fired, e.g. "Xcode 180%".
    var culprit: String?
}

/// What changed on one update, for work only the engine can do.
struct AttentionChange: Equatable {
    /// Conditions that have just begun and are now waiting out their delay.
    var dwellStarted: Set<AttentionKind> = []
    /// Warnings that have just become active.
    var raised: Set<AttentionKind> = []
}

extension ProcessSample {
    /// The biggest user of the resource behind a warning, as display text.
    ///
    /// nil when nothing here stands out. `cpu` is the system reading the
    /// warning was raised on, and it is what tells a culprit from a bystander.
    func culprit(for kind: AttentionKind, cpu: CPUSample) -> String? {
        switch kind {
        case .cpu:
            let readable = rows.reduce(0) { $0 + $1.cpu }
            guard state == .ready, let top = ranked(by: .cpu, filter: .all).first,
                  Self.explains(top: top.cpu, readable: readable, load: cpu.busyCores) else { return nil }
            return "\(top.name) \(Format.percent(top.cpu))"
        case .memory:
            // Resident memory needs no earlier scan to measure against, so a
            // sample still waiting on its CPU figures can already name this.
            guard let top = ranked(by: .memory, filter: .all).first else { return nil }
            return "\(top.name) \(Format.bytes(top.memory))"
        case .disk, .thermal:
            return nil
        }
    }

    /// Whether the busiest readable process, at `top` cores, can be named for
    /// a load of `load` cores when every readable process came to `readable`.
    ///
    /// Root-owned processes cannot be read without root, so a load that
    /// belongs to one leaves only bystanders in this list, and a floor of a
    /// quarter of a core is no test on a machine with ten: seven of them busy
    /// in `mds_stores` would still name a browser idling at 30%. So the top
    /// process has to be a real part of the load itself, or the processes
    /// that can be read have to cover most of it, in which case the largest
    /// of them is a fair name even if the work is spread across many. Neither
    /// means the load is somewhere this list cannot see, and nothing is named.
    static func explains(top: Double, readable: Double, load: Double) -> Bool {
        guard top >= 0.25, load > 0 else { return false }
        return top >= load / 4 || readable >= load / 2
    }
}

/// Local warning history. No notifications or extra timer. Process scans happen
/// only around a warning firing, never while nothing is wrong.
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

    /// Names whoever was responsible for an active warning, or nobody.
    ///
    /// Called only as a warning is raised, so nil replaces the old name rather
    /// than being skipped. A warning reopened after sleep is a new episode
    /// under the same title, and if this time the load cannot be traced, the
    /// app blamed before the sleep must not stay on it.
    mutating func setCulprit(_ culprit: String?, for kind: AttentionKind) {
        guard let index = events.lastIndex(where: { $0.kind == kind && $0.endedAt == nil }) else { return }
        events[index].culprit = culprit
    }

    @discardableResult
    mutating func update(snapshot: Snapshot, thresholds: Config.Thresholds, at time: TimeInterval) -> AttentionChange {
        var change = AttentionChange()
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
            if pending[kind] == nil {
                pending[kind] = time
                change.dwellStarted.insert(kind)
            }
            guard time - (pending[kind] ?? time) >= delay else { continue }
            if let index = events.firstIndex(where: { $0.kind == kind && $0.endedAt == nil }) {
                events[index].title = title
                events[index].detail = detail
            } else if let index = interruptedEvent(of: kind, at: time) {
                events[index].title = title
                events[index].detail = detail
                events[index].endedAt = nil
                events[index].interrupted = nil
                change.raised.insert(kind)
            } else {
                events.append(AttentionEvent(kind: kind, title: title, detail: detail, startedAt: pending[kind] ?? time))
                change.raised.insert(kind)
            }
        }
        events.removeAll { ($0.endedAt ?? time) < time - 3600 }
        if events.count > 20 {
            // Preserve ongoing conditions; discard the oldest completed events first.
            while events.count > 20, let index = events.firstIndex(where: { $0.endedAt != nil }) {
                events.remove(at: index)
            }
        }
        return change
    }
}

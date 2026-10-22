import Foundation
import OSLog

/// Only chart buckets and warning events are persisted. Live readings,
/// process identities, and session transfer totals always start fresh.
struct HistoryArchive: Codable {
    var version = 1
    var savedAt: TimeInterval
    var cpu: [HistoryPoint]
    var memory: [HistoryPoint]
    var download: [HistoryPoint]
    var upload: [HistoryPoint]
    var diskRead: [HistoryPoint]
    var diskWrite: [HistoryPoint]
    var attention: [AttentionEvent]

    init(snapshot: Snapshot) {
        savedAt = snapshot.sampledAt
        let duration = HistoryWindow.oneHour.rawValue
        cpu = snapshot.cpuHistory.points(endingAt: savedAt, duration: duration)
        memory = snapshot.memoryHistory.points(endingAt: savedAt, duration: duration)
        download = snapshot.downloadHistory.points(endingAt: savedAt, duration: duration)
        upload = snapshot.uploadHistory.points(endingAt: savedAt, duration: duration)
        diskRead = snapshot.diskReadHistory.points(endingAt: savedAt, duration: duration)
        diskWrite = snapshot.diskWriteHistory.points(endingAt: savedAt, duration: duration)
        attention = Array(snapshot.attention.suffix(20))
    }

    func recoveredSnapshot(at now: TimeInterval) -> Snapshot? {
        guard version == 1, savedAt.isFinite, savedAt > 0, now.isFinite,
              savedAt <= now, now - savedAt <= HistoryWindow.oneHour.rawValue else { return nil }
        var snapshot = Snapshot()
        snapshot.sampledAt = now
        func restore(_ points: [HistoryPoint], ceiling: Double = .infinity) -> MetricHistory {
            MetricHistory(restoring: points.filter { $0.time <= savedAt && $0.value <= ceiling }, endingAt: now)
        }
        snapshot.cpuHistory = restore(cpu, ceiling: 1)
        snapshot.memoryHistory = restore(memory, ceiling: 1)
        snapshot.downloadHistory = restore(download)
        snapshot.uploadHistory = restore(upload)
        snapshot.diskReadHistory = restore(diskRead)
        snapshot.diskWriteHistory = restore(diskWrite)
        // An ongoing condition ended at the last observed sample. Relaunching
        // must establish any new warning from fresh evidence and dwell time.
        snapshot.attention = attention.compactMap { event in
            let end = min(event.endedAt ?? savedAt, savedAt)
            guard event.startedAt.isFinite, event.endedAt?.isFinite != false, end.isFinite, event.startedAt <= end,
                  end >= now - HistoryWindow.oneHour.rawValue else { return nil }
            var closed = event
            closed.endedAt = end
            return closed
        }.sorted { $0.startedAt < $1.startedAt }
        snapshot.attention = Array(snapshot.attention.suffix(20))
        return snapshot
    }
}

/// Save on the existing sampling tick at most once per minute, and flush on
/// normal quit or sleep. Disk work runs in order on a utility queue.
final class HistoryStore {
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vitals", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    private let url: URL
    private let uptime: () -> TimeInterval
    private let queue = DispatchQueue(label: "com.ashakur.vitals.history", qos: .utility)
    private var lastCheckpoint: TimeInterval?
    private static let logger = Logger(subsystem: "com.ashakur.vitals", category: "history")
    private static let maxFileSize = 1_048_576

    init(url: URL = HistoryStore.defaultURL,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.url = url
        self.uptime = uptime
    }

    func load(at now: TimeInterval) -> Snapshot? {
        // Bound reads before decoding; corrupt, old, or unknown files simply
        // start a fresh history and are replaced by the next checkpoint.
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= Self.maxFileSize,
              let data = try? Data(contentsOf: url),
              let archive = try? JSONDecoder().decode(HistoryArchive.self, from: data) else { return nil }
        return archive.recoveredSnapshot(at: now)
    }

    func checkpoint(_ snapshot: Snapshot, force: Bool = false) {
        guard snapshot.sampledAt > 0 else { return }
        let now = uptime()
        if !force, let previous = lastCheckpoint, now >= previous, now - previous < 60 { return }
        lastCheckpoint = now
        let archive = HistoryArchive(snapshot: snapshot)
        let destination = url
        queue.async { Self.write(archive, to: destination) }
    }

    func flush(_ snapshot: Snapshot? = nil) {
        if let snapshot { checkpoint(snapshot, force: true) }
        queue.sync {}
    }

    private static func write(_ archive: HistoryArchive, to url: URL) {
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(archive)
            try data.write(to: url, options: [.atomic])
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            logger.error("Could not save metric history: \(error.localizedDescription, privacy: .public)")
        }
    }
}

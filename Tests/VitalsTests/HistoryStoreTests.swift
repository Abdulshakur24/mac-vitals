import XCTest
@testable import Vitals

final class HistoryStoreTests: XCTestCase {
    private func destination() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VitalsHistoryTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("history.json")
    }

    private func snapshot(at time: TimeInterval = 10_000) -> Snapshot {
        var snapshot = Snapshot()
        snapshot.sampledAt = time
        snapshot.cpuHistory.append(0.4, at: time - 10, interval: 1)
        snapshot.cpuHistory.markGap()
        snapshot.cpuHistory.append(0.8, at: time, interval: 1)
        snapshot.memoryHistory.append(0.6, at: time, interval: 1)
        snapshot.downloadHistory.append(1234, at: time, interval: 1)
        snapshot.uploadHistory.append(2345, at: time, interval: 1)
        snapshot.diskReadHistory.append(3456, at: time, interval: 1)
        snapshot.diskWriteHistory.append(4567, at: time, interval: 1)
        snapshot.attention = [AttentionEvent(kind: .cpu, title: "High CPU", detail: "80%", startedAt: time - 20)]
        snapshot.cpu = CPUSample(total: 0.8, user: 0.4, system: 0.4, perCore: [0.8])
        snapshot.network.sessionReceived = 100_000
        snapshot.processes = ProcessSample(rows: [.init(pid: 42, started: 1, name: "private-process-name", cpu: 1, memory: 1)], state: .ready)
        return snapshot
    }

    func testRoundTripRestoresAllChartsAndClosesWarningsWithoutStaleLiveValues() throws {
        let url = try destination()
        let original = snapshot()
        let store = HistoryStore(url: url)
        store.flush(original)
        let restored = try XCTUnwrap(store.load(at: 10_010))
        for key in [\Snapshot.cpuHistory, \.memoryHistory, \.downloadHistory, \.uploadHistory, \.diskReadHistory, \.diskWriteHistory] {
            XCTAssertEqual(restored[keyPath: key].points(endingAt: 10_010, duration: 3600),
                           original[keyPath: key].points(endingAt: 10_010, duration: 3600))
        }
        XCTAssertEqual(restored.attention.first?.endedAt, 10_000)
        XCTAssertEqual(restored.attention.first?.id, original.attention.first?.id)
        XCTAssertEqual(restored.cpu, CPUSample())
        XCTAssertEqual(restored.network.sessionReceived, 0)
        XCTAssertEqual(restored.processes.state, .sampling)
        XCTAssertTrue(restored.processes.rows.isEmpty)
        let data = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(data.contains("private-process-name"))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testRestoredHistoryAlwaysStartsNewSegmentEvenInsideSameBucket() {
        let points = [HistoryPoint(time: 100, value: 0.8, startsSegment: true)]
        var history = MetricHistory(restoring: points, endingAt: 100.1)
        history.append(0.2, at: 101, interval: 1)
        let restored = history.points(endingAt: 101, duration: 300)
        XCTAssertEqual(restored.map(\.value), [0.8, 0.2])
        XCTAssertEqual(restored.map(\.startsSegment), [true, true])
    }

    func testCorruptUnknownFutureExpiredAndOversizedFilesStartFresh() throws {
        let url = try destination()
        let store = HistoryStore(url: url)
        XCTAssertNil(store.load(at: 10_010))
        try Data("broken".utf8).write(to: url)
        XCTAssertNil(store.load(at: 10_010))
        var archive = HistoryArchive(snapshot: snapshot())
        archive.version = 999
        try JSONEncoder().encode(archive).write(to: url)
        XCTAssertNil(store.load(at: 10_010))
        archive.version = 1
        try JSONEncoder().encode(archive).write(to: url)
        XCTAssertNil(store.load(at: 9999))
        XCTAssertNil(store.load(at: 13_601))
        try Data(repeating: 0, count: 1_048_577).write(to: url)
        XCTAssertNil(store.load(at: 10_010))
        store.flush(snapshot())
        XCTAssertNotNil(store.load(at: 10_010))
    }

    func testRestorationFiltersInvalidAndExpiredPointsAndBoundsStorage() {
        let points = (0..<1000).map { HistoryPoint(time: Double($0), value: 0.5, startsSegment: false) }
            + [HistoryPoint(time: .nan, value: 1, startsSegment: false),
               HistoryPoint(time: 1000, value: -.infinity, startsSegment: false),
               HistoryPoint(time: 1001, value: 1, startsSegment: false)]
        let history = MetricHistory(restoring: points, endingAt: 999)
        let restored = history.points(endingAt: 999, duration: 3600)
        XCTAssertEqual(restored.count, 721)
        XCTAssertEqual(restored.last?.time, 999)
        XCTAssertEqual(restored.first?.startsSegment, true)
        let cutoff = MetricHistory(restoring: [HistoryPoint(time: 100, value: 1, startsSegment: true)], endingAt: 4000)
        XCTAssertTrue(cutoff.points(endingAt: 4000, duration: 3600).isEmpty)
    }

    func testCheckpointThrottlesWritesAndShutdownFlushesLatestSample() throws {
        let url = try destination()
        var uptime = 0.0
        let store = HistoryStore(url: url, uptime: { uptime })
        store.checkpoint(snapshot())
        store.flush()
        uptime = 10
        store.checkpoint(snapshot(at: 10_001))
        store.flush()
        func savedAt() throws -> Double {
            try JSONDecoder().decode(HistoryArchive.self, from: Data(contentsOf: url)).savedAt
        }
        XCTAssertEqual(try savedAt(), 10_000)
        uptime = 60
        store.checkpoint(snapshot(at: 10_002))
        store.flush()
        XCTAssertEqual(try savedAt(), 10_002)
        store.flush(snapshot(at: 10_003))
        XCTAssertEqual(try savedAt(), 10_003)
    }

    func testRestoredWarningMustEstablishFreshDwellTime() throws {
        let archive = HistoryArchive(snapshot: snapshot())
        let restored = try XCTUnwrap(archive.recoveredSnapshot(at: 10_010))
        var tracker = AttentionTracker()
        tracker.restore(restored.attention)
        tracker.update(snapshot: snapshot(at: 10_010), thresholds: .init(), at: 10_010)
        XCTAssertTrue(tracker.events.allSatisfy { $0.endedAt != nil })
        tracker.update(snapshot: snapshot(at: 10_025), thresholds: .init(), at: 10_025)
        XCTAssertEqual(tracker.events.filter { $0.endedAt == nil }.map(\.startedAt), [10_010])
    }

    @MainActor
    func testEngineRestoresHistoryAndSavesOnShutdown() throws {
        let url = try destination()
        let now = Date().timeIntervalSince1970
        let store = HistoryStore(url: url)
        store.flush(snapshot(at: now - 10))
        let engine = MetricsEngine(historyStore: store)
        XCTAssertEqual(engine.snapshot.cpuHistory.points(endingAt: now, duration: 3600).count, 2)
        XCTAssertTrue(engine.snapshot.attention.allSatisfy { $0.endedAt != nil })
        engine.isTemperatureShown = { false }
        engine.start()
        engine.saveHistory()
        let restored = try XCTUnwrap(HistoryStore(url: url).load(at: Date().timeIntervalSince1970))
        XCTAssertFalse(restored.memoryHistory.points(endingAt: Date().timeIntervalSince1970, duration: 3600).isEmpty)
        XCTAssertTrue(restored.processes.rows.isEmpty)
    }
}

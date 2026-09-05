import XCTest
import Darwin
@testable import Vitals

final class VitalsTests: XCTestCase {
    func testThresholdValidationAndRoundTrip() throws {
        var config = Config()
        config.thresholds = .init(cpu: 0.35, temperature: 75, diskFree: 0.2)
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config)).validated()
        XCTAssertEqual(decoded.thresholds, config.thresholds)
        config.thresholds = .init(cpu: 5, temperature: -4, diskFree: -1)
        config.sampleInterval = .nan
        let bounded = config.validated()
        XCTAssertEqual(bounded.thresholds, .init(cpu: 1, temperature: 1, diskFree: 0))
        XCTAssertEqual(bounded.sampleInterval, 1)
    }

    func testHistoryUsesTimeNotSampleCountAndRetainsPeaks() {
        var history = MetricHistory()
        history.append(0.2, at: 100, interval: 1)
        history.append(0.9, at: 101, interval: 1)
        history.append(0.3, at: 104, interval: 1)
        history.append(0.4, at: 110, interval: 2)
        let points = history.points(endingAt: 110, duration: 300)
        XCTAssertEqual(points.map(\.value), [0.9, 0.4])
        XCTAssertEqual(points.map(\.time), [104, 110])
        XCTAssertEqual(history.points(endingAt: 410, duration: 300).count, 1)
        XCTAssertTrue(history.points(endingAt: 411, duration: 300).isEmpty)
    }

    func testHourHistoryHasBoundedStorageAndCorrectWindow() {
        var history = MetricHistory()
        for time in stride(from: 0.0, through: 10_000, by: 0.5) {
            history.append(time, at: time, interval: 0.5)
        }
        let hour = history.points(endingAt: 10_000, duration: 3600)
        XCTAssertLessThanOrEqual(hour.count, 721)
        XCTAssertGreaterThanOrEqual(hour.first!.time, 6400)
        XCTAssertEqual(hour.last!.value, 10_000)
        XCTAssertLessThanOrEqual(history.points(endingAt: 10_000, duration: 300).count, 61)
    }

    func testSleepAndMissingSamplesBreakChartSegments() {
        var history = MetricHistory()
        history.append(1, at: 100, interval: 1)
        history.markGap()
        history.append(2, at: 102, interval: 1)
        history.append(3, at: 107, interval: 1)
        history.append(4, at: 200, interval: 1)
        let points = history.points(endingAt: 200, duration: 300)
        XCTAssertEqual(points.map(\.startsSegment), [true, true, false, true])
    }

    func testShortAddressRecordDoesNotHideFollowingInterface() {
        var message = if_msghdr2()
        message.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.stride + 20)
        message.ifm_type = UInt8(RTM_IFINFO2)
        message.ifm_flags = IFF_UP | IFF_RUNNING
        message.ifm_index = 9
        message.ifm_data.ifi_ibytes = 12345
        var bytes: [UInt8] = [8, 0, 5, UInt8(RTM_NEWADDR), 0, 0, 0, 0]
        withUnsafeBytes(of: message) { bytes.append(contentsOf: $0) }
        bytes += [20, UInt8(AF_LINK), 9, 0, 6, 3, 0, 0] + Array("en0".utf8) + [UInt8](repeating: 0, count: 9)
        let interfaces = NetworkSampler.interfaceCounters(in: bytes)
        XCTAssertEqual(interfaces["en0"]?.received, 12345)
        XCTAssertEqual(interfaces["en0"]?.index, 9)
        XCTAssertEqual(interfaces.count, 1)
        XCTAssertTrue(NetworkSampler.interfaceCounters(in: [0, 0, 0, 0]).isEmpty)
    }

    func testShortVariableLengthInterfaceRecord() {
        let headerSize = MemoryLayout<if_msghdr2>.stride
        var bytes = [UInt8](repeating: 0, count: headerSize + 12)
        bytes[headerSize] = 12
        bytes[headerSize + 5] = 3
        bytes.replaceSubrange((headerSize + 8)..<(headerSize + 11), with: Array("en0".utf8))
        bytes.withUnsafeBytes { raw in
            XCTAssertEqual(NetworkSampler.interfaceName(base: raw.baseAddress!, offset: 0, limit: bytes.count), "en0")
            XCTAssertEqual(NetworkSampler.interfaceName(base: raw.baseAddress!, offset: 0, limit: bytes.count - 2), "")
        }
    }

    func testNetworkResetDoesNotInventFourGigabytes() {
        XCTAssertEqual(NetworkSampler.counterDelta(new: 10, old: 1_000_000, elapsed: 1, baudrate: 1_000_000_000), 0)
        let modulus = UInt64(UInt32.max) + 1
        XCTAssertEqual(NetworkSampler.counterDelta(new: 20, old: modulus - 10, elapsed: 1, baudrate: 1_000_000_000), 30)
        XCTAssertEqual(NetworkSampler.counterDelta(new: 20, old: modulus - 10, elapsed: 60, baudrate: 1_000_000_000), 0)
        XCTAssertEqual(NetworkSampler.counterDelta(new: 20, old: modulus - 10, elapsed: 1, baudrate: 0), 0)
        XCTAssertEqual(NetworkSampler.counterDelta(new: 1, old: modulus + 10, elapsed: 1, baudrate: 1_000_000_000), 0)
        XCTAssertEqual(NetworkSampler.counterDelta(new: modulus + 50, old: modulus + 10, elapsed: 1, baudrate: 0), 40)
    }

    func testNetworkReconnectIdentityChangeAndWakeRebaseline() {
        let sampler = NetworkSampler()
        _ = sampler.consume(["en0": .init(received: 100, sent: 100, index: 1)], at: 10)
        let live = sampler.consume(["en0": .init(received: 300, sent: 120, index: 1)], at: 12)
        XCTAssertEqual(live.download, 100)
        XCTAssertEqual(live.sessionReceived, 200)
        let replaced = sampler.consume(["en0": .init(received: 3_000_000, sent: 10, index: 2)], at: 13)
        XCTAssertEqual(replaced.download, 0)
        XCTAssertEqual(sampler.consume([:], at: 14).interface, "")
        XCTAssertEqual(sampler.consume(["en0": .init(received: 5_000_000, sent: 10, index: 2)], at: 15).download, 0)
        sampler.resetBaseline()
        XCTAssertEqual(sampler.consume(["en0": .init(received: 7_000_000, sent: 10, index: 2)], at: 16).sessionReceived, 200)
    }

    func testBusiestInterfaceUsesCurrentDelta() {
        let sampler = NetworkSampler()
        _ = sampler.consume(["en0": .init(received: 1_000_000, sent: 0), "en1": .init(received: 1, sent: 0)], at: 1)
        let next = sampler.consume(["en0": .init(received: 1_000_001, sent: 0), "en1": .init(received: 1000, sent: 0)], at: 2)
        XCTAssertEqual(next.interface, "en1")
        XCTAssertEqual(next.download, 1000)
    }

    func testCPUAttentionRequiresSustainedLoadAndResolves() {
        var tracker = AttentionTracker()
        var snapshot = Snapshot()
        snapshot.cpu = CPUSample(total: 0.8, perCore: [0.8])
        tracker.update(snapshot: snapshot, thresholds: .init(), at: 100)
        tracker.update(snapshot: snapshot, thresholds: .init(), at: 114)
        XCTAssertTrue(tracker.events.isEmpty)
        tracker.update(snapshot: snapshot, thresholds: .init(), at: 115)
        XCTAssertEqual(tracker.events.count, 1)
        tracker.update(snapshot: snapshot, thresholds: .init(), at: 120)
        XCTAssertEqual(tracker.events.count, 1)
        snapshot.cpu.total = 0.1
        tracker.update(snapshot: snapshot, thresholds: .init(), at: 121)
        XCTAssertEqual(tracker.events.first?.endedAt, 121)
        tracker.update(snapshot: snapshot, thresholds: .init(), at: 4000)
        XCTAssertTrue(tracker.events.isEmpty)
    }

    func testAttentionHonorsConfigAndIgnoresUnavailableMetrics() {
        var tracker = AttentionTracker()
        var snapshot = Snapshot()
        tracker.update(snapshot: snapshot, thresholds: .init(), at: 100)
        XCTAssertTrue(tracker.events.isEmpty)
        snapshot.disk = DiskSample(free: 15, total: 100)
        tracker.update(snapshot: snapshot, thresholds: .init(diskFree: 0.2), at: 101)
        XCTAssertEqual(tracker.events.first?.kind, .disk)
        tracker.update(snapshot: snapshot, thresholds: .init(diskFree: 0.1), at: 102)
        XCTAssertEqual(tracker.events.first?.endedAt, 102)
        snapshot.thermal.state = .serious // no private temperature sensor required
        tracker.update(snapshot: snapshot, thresholds: .init(), at: 103)
        XCTAssertEqual(tracker.events.last?.kind, .thermal)
    }

    func testSleepDoesNotCountTowardSustainedWarning() {
        var tracker = AttentionTracker()
        var snapshot = Snapshot()
        snapshot.cpu = CPUSample(total: 0.9, perCore: [0.9])
        tracker.update(snapshot: snapshot, thresholds: .init(), at: 100)
        tracker.interrupt(at: 105)
        tracker.update(snapshot: snapshot, thresholds: .init(), at: 500)
        XCTAssertTrue(tracker.events.isEmpty)
    }
}

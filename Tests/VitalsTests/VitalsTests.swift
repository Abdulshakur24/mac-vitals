import AppKit
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

    func testSleepContinuesAWarningInsteadOfDuplicatingIt() {
        var tracker = AttentionTracker()
        var snapshot = Snapshot()
        snapshot.disk = DiskSample(free: 5, total: 100)
        tracker.update(snapshot: snapshot, thresholds: .init(), at: 100)
        tracker.interrupt(at: 200)
        XCTAssertEqual(tracker.events.first?.endedAt, 200)
        // Low disk space is the same event however long the sleep was.
        tracker.update(snapshot: snapshot, thresholds: .init(), at: 3000)
        XCTAssertEqual(tracker.events.count, 1)
        XCTAssertEqual(tracker.events.first?.startedAt, 100)
        XCTAssertNil(tracker.events.first?.endedAt)
    }

    func testRecoveredConditionsAndLongGapsStartAFreshEvent() {
        var tracker = AttentionTracker()
        var snapshot = Snapshot()
        snapshot.cpu = CPUSample(total: 0.9, perCore: [0.9])
        tracker.update(snapshot: snapshot, thresholds: .init(), at: 100)
        tracker.update(snapshot: snapshot, thresholds: .init(), at: 115)
        tracker.interrupt(at: 120)
        // Back within the window: dwell is still earned, then it continues.
        tracker.update(snapshot: snapshot, thresholds: .init(), at: 200)
        tracker.update(snapshot: snapshot, thresholds: .init(), at: 214)
        XCTAssertEqual(tracker.events.first?.endedAt, 120)
        tracker.update(snapshot: snapshot, thresholds: .init(), at: 215)
        XCTAssertEqual(tracker.events.count, 1)
        XCTAssertNil(tracker.events.first?.endedAt)
        // Past the window it is a different episode.
        tracker.interrupt(at: 300)
        tracker.update(snapshot: snapshot, thresholds: .init(), at: 1000)
        tracker.update(snapshot: snapshot, thresholds: .init(), at: 1015)
        XCTAssertEqual(tracker.events.count, 2)
        // A condition that genuinely cleared is never reopened.
        snapshot.cpu.total = 0.1
        tracker.update(snapshot: snapshot, thresholds: .init(), at: 1016)
        snapshot.cpu.total = 0.9
        tracker.update(snapshot: snapshot, thresholds: .init(), at: 1017)
        tracker.update(snapshot: snapshot, thresholds: .init(), at: 1032)
        XCTAssertEqual(tracker.events.count, 3)
    }

    func testHistoryFilesWrittenBeforeNewEventFieldsStillDecode() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"disk","title":"t","detail":"d","startedAt":1}"#
        let event = try JSONDecoder().decode(AttentionEvent.self, from: Data(json.utf8))
        XCTAssertNil(event.interrupted)
    }

    func testBytesDropTheDecimalOnlyWhereItIsNoise() {
        XCTAssertEqual(Format.bytes(512), "512 B")
        XCTAssertEqual(Format.bytes(1536 << 10), "1.5 MB")
        XCTAssertEqual(Format.bytes(99 << 20), "99.0 MB")
        XCTAssertEqual(Format.bytes(900 << 20), "900 MB")
        XCTAssertEqual(Format.bytes(460 << 30), "460 GB")
    }

    func testChartSummaryOverItsWindow() {
        let points = [0.2, 0.8, 0.5].enumerated().map { HistoryPoint(time: Double($0), value: $1, startsSegment: false) }
        XCTAssertEqual(points.peak, 0.8)
        XCTAssertEqual(points.summary(Format.percent), "peak 80% · avg 50%")
        XCTAssertEqual([HistoryPoint]().summary(Format.percent), "")
    }

    func testDurationReadsTheWayPeopleSayIt() {
        XCTAssertEqual(Format.duration(45), "45 s")
        XCTAssertEqual(Format.duration(420), "7 min")
        XCTAssertEqual(Format.duration(4320), "1 h 12 min")
        XCTAssertEqual(Format.duration(7200), "2 h")
    }

    func testPartialConfigKeepsEverythingElseAtDefaults() throws {
        func decode(_ json: String) throws -> Config {
            try JSONDecoder().decode(Config.self, from: Data(json.utf8)).validated()
        }
        let onlyMenuBar = try decode(#"{"menuBar":["cpu","memory"]}"#)
        XCTAssertEqual(onlyMenuBar.menuBar, [.cpu, .memory])
        XCTAssertEqual(onlyMenuBar.sampleInterval, Config.default.sampleInterval)
        XCTAssertEqual(onlyMenuBar.thresholds, Config.default.thresholds)

        let onlyOneThreshold = try decode(#"{"thresholds":{"cpu":0.5}}"#)
        XCTAssertEqual(onlyOneThreshold.thresholds, .init(cpu: 0.5))
        XCTAssertEqual(onlyOneThreshold.menuBar, Config.default.menuBar)

        XCTAssertEqual(try decode("{}"), Config.default)
    }

    func testUnknownMetricIsSkippedNotFatal() throws {
        func decode(_ json: String) throws -> Config {
            try JSONDecoder().decode(Config.self, from: Data(json.utf8)).validated()
        }
        XCTAssertEqual(try decode(#"{"menuBar":["cpu","gpu","network"],"sampleInterval":2}"#).menuBar,
                       [.cpu, .network])
        XCTAssertEqual(try decode(#"{"menuBar":["cpu","gpu","network"],"sampleInterval":2}"#).sampleInterval, 2)
        // Nothing usable left falls back to the default rather than an empty bar.
        XCTAssertEqual(try decode(#"{"menuBar":["gpu"]}"#).menuBar, Config.default.menuBar)
        // A value of the wrong type is still rejected.
        XCTAssertThrowsError(try decode(#"{"sampleInterval":"fast"}"#))
    }

    func testIdleNetworkKeepsItsInterfaceAndPrefersConnectedOnes() {
        let sampler = NetworkSampler()
        let up = ["awdl0": NetworkSampler.Counters(received: 5, sent: 5),
                  "en0": NetworkSampler.Counters(received: 100, sent: 100)]
        // Nothing has moved yet: awdl0 sorts first, but en0 is the connected one.
        XCTAssertEqual(sampler.consume(up, at: 1, addressed: ["en0"]).interface, "en0")
        XCTAssertEqual(sampler.consume(up, at: 2, addressed: ["en0"]).interface, "en0")
        // Even with no addressed interface to go by, the label does not flip.
        XCTAssertEqual(sampler.consume(up, at: 3).interface, "en0")
        // Traffic elsewhere still wins.
        var busy = up
        busy["awdl0"] = .init(received: 5000, sent: 5)
        XCTAssertEqual(sampler.consume(busy, at: 4, addressed: ["en0"]).interface, "awdl0")
        // And an interface that has gone away is not kept.
        XCTAssertEqual(sampler.consume(["en1": .init(received: 1, sent: 1)], at: 5).interface, "en1")
    }
}

final class MenuBarReadoutTests: XCTestCase {
    private let layout = MenuBarLayout.ladder(for: [.cpu, .memory, .network, .temperature])[0]

    private func snapshot(at time: TimeInterval, cpu: Double = 0.12) -> Snapshot {
        var snapshot = Snapshot()
        snapshot.sampledAt = time
        snapshot.cpu = CPUSample(total: cpu, perCore: [cpu])
        snapshot.memory = MemorySample(total: 24 << 30, used: 16 << 30)
        snapshot.cpuHistory.append(cpu, at: time, interval: 1)
        return snapshot
    }

    func testReadingsThatDrawTheSameDoNotChangeTheReadout() {
        // 12.1% and 12.4% draw identically, and the clock moves within a bucket.
        let first = MenuBarReadout(layout: layout, snapshot: snapshot(at: 1001, cpu: 0.121), thresholds: .init())
        let second = MenuBarReadout(layout: layout, snapshot: snapshot(at: 1002, cpu: 0.124), thresholds: .init())
        XCTAssertEqual(first, second)
    }

    func testVisibleChangesDo() {
        let base = MenuBarReadout(layout: layout, snapshot: snapshot(at: 1001), thresholds: .init())
        // A new bucket slides the older points of the sparkline left.
        var older = snapshot(at: 1001)
        older.cpuHistory.append(0.12, at: 1006, interval: 1)
        older.sampledAt = 1006
        var later = older
        later.cpuHistory.append(0.12, at: 1011, interval: 1)
        later.sampledAt = 1011
        let before = MenuBarReadout(layout: layout, snapshot: older, thresholds: .init()).blocks[0].sparkline
        let after = MenuBarReadout(layout: layout, snapshot: later, thresholds: .init()).blocks[0].sparkline
        XCTAssertLessThan(after[0][0].x, before[0][0].x)
        // A different number.
        XCTAssertNotEqual(base, MenuBarReadout(layout: layout, snapshot: snapshot(at: 1001, cpu: 0.2), thresholds: .init()))
        // The same number crossing into an alert.
        XCTAssertNotEqual(base, MenuBarReadout(layout: layout, snapshot: snapshot(at: 1001), thresholds: .init(cpu: 0.1)))
    }

    func testMissingTemperatureDrawsNothingAndCompactDropsTheSparkline() throws {
        let readout = MenuBarReadout(layout: layout, snapshot: snapshot(at: 1001), thresholds: .init())
        XCTAssertEqual(readout.blocks.first { $0.metric == .temperature }?.rows, [])
        XCTAssertFalse(try XCTUnwrap(readout.blocks.first).sparkline.isEmpty)
        let compact = try XCTUnwrap(MenuBarLayout.ladder(for: [.cpu]).last)
        XCTAssertEqual(MenuBarReadout(layout: compact, snapshot: snapshot(at: 1001), thresholds: .init()).blocks.first?.sparkline, [])
    }

    func testTemplateBitmapDrawsAtFullSizeAcrossItsWidth() throws {
        var sample = snapshot(at: 1001)
        sample.thermal.cpu = 44
        let readout = MenuBarReadout(layout: layout, snapshot: sample, thresholds: .init())
        let image = MenuBarRenderer.image(for: readout)
        XCTAssertTrue(image.isTemplate)
        let bitmap = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(bitmap.pixelsWide, Int(readout.width) * 2)
        // Temperature is the last block. Drawn at 1x it would stop near the middle.
        let inked = (bitmap.pixelsWide * 3 / 4..<bitmap.pixelsWide).contains { x in
            (0..<bitmap.pixelsHigh).contains { y in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 }
        }
        XCTAssertTrue(inked)
    }

    func testAlertsAreDrawnInColour() {
        let readout = MenuBarReadout(layout: layout, snapshot: snapshot(at: 1001), thresholds: .init(cpu: 0.1))
        XCTAssertFalse(MenuBarRenderer.image(for: readout).isTemplate)
    }

    func testOnlyAlertsAndWidthSkipTheRefreshGap() {
        let base = MenuBarReadout(layout: layout, snapshot: snapshot(at: 1001), thresholds: .init())
        let digits = MenuBarReadout(layout: layout, snapshot: snapshot(at: 1001, cpu: 0.2), thresholds: .init())
        XCTAssertFalse(digits.isUrgent(comparedTo: base))
        let alert = MenuBarReadout(layout: layout, snapshot: snapshot(at: 1001), thresholds: .init(cpu: 0.1))
        XCTAssertTrue(alert.isUrgent(comparedTo: base))
        XCTAssertTrue(base.isUrgent(comparedTo: alert))
        let narrower = MenuBarLayout.ladder(for: [.cpu, .memory, .network, .temperature])[1]
        XCTAssertTrue(MenuBarReadout(layout: narrower, snapshot: snapshot(at: 1001), thresholds: .init()).isUrgent(comparedTo: base))
    }

    func testSummaryCoversMetricsTheBarHasDroppedAndSaysNothingBeforeASample() {
        var sample = snapshot(at: 1001)
        sample.thermal.cpu = 44
        sample.attention = [AttentionEvent(kind: .disk, title: "Disk space is low", detail: "", startedAt: 1)]
        XCTAssertTrue(sample.summary.contains("Temperature 44°"))
        XCTAssertTrue(sample.summary.hasSuffix("Disk space is low"))
        XCTAssertEqual(Snapshot().summary, "Vitals")
    }
}

final class CoreLayoutTests: XCTestCase {
    func testThisMacsEfficiencyFirstOrderIsNotMislabelled() {
        // M4: cpu0–5 are E and cpu6–9 are P, the reverse of what a count assumes.
        let kinds = Dictionary(uniqueKeysWithValues: (0..<10).map { ($0, $0 < 6 ? "E" : "P") })
        let layout = CoreLayout(kinds: kinds, coreCount: 10)
        XCTAssertEqual(layout.groups, [.init(label: "P", indices: [6, 7, 8, 9]),
                                       .init(label: "E", indices: [0, 1, 2, 3, 4, 5])])
        XCTAssertEqual(layout.count("P"), 4)
        XCTAssertEqual(layout.count("E"), 6)
    }

    func testUnknownKindsGiveOneUnlabelledGroupRatherThanAGuess() {
        let unlabelled = [CoreLayout.Group(label: nil, indices: [0, 1, 2])]
        XCTAssertEqual(CoreLayout(kinds: [:], coreCount: 3).groups, unlabelled)
        XCTAssertEqual(CoreLayout(kinds: [0: "E", 1: "P"], coreCount: 3).groups, unlabelled)
        XCTAssertEqual(CoreLayout(kinds: [0: "E", 1: "P", 2: "M"], coreCount: 3).groups, unlabelled)
    }

    func testRegistryReadMatchesThisMachine() {
        let kinds = CoreLayout.readKinds()
        XCTAssertEqual(kinds.count, ProcessInfo.processInfo.processorCount)
        XCTAssertTrue(Set(kinds.values).isSubset(of: ["P", "E"]))
    }
}

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

    /// A VPN's bytes cross its tunnel and then, encrypted, Wi-Fi or Ethernet;
    /// a VM's cross a bridge and then a physical port. Counting both shows the
    /// same transfer twice, so only physical interfaces are kept.
    func testTunnelsAndBridgesAreNotCountedTwice() {
        func record(_ name: String, index: UInt16) -> [UInt8] {
            var message = if_msghdr2()
            message.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.stride + 20)
            message.ifm_type = UInt8(RTM_IFINFO2)
            message.ifm_flags = IFF_UP | IFF_RUNNING
            message.ifm_index = index
            message.ifm_data.ifi_ibytes = 1000
            var bytes: [UInt8] = []
            withUnsafeBytes(of: message) { bytes.append(contentsOf: $0) }
            let nameBytes = Array(name.utf8)
            bytes += [20, UInt8(AF_LINK), UInt8(index), 0, 6, UInt8(nameBytes.count), 0, 0] + nameBytes
                + [UInt8](repeating: 0, count: 12 - nameBytes.count)
            return bytes
        }
        let names = ["en0", "utun4", "ipsec0", "ppp0", "bridge100", "vmenet0", "awdl0", "en5"]
        let buffer = names.enumerated().flatMap { offset, name in record(name, index: UInt16(offset + 1)) }
        XCTAssertEqual(Set(NetworkSampler.interfaceCounters(in: buffer).keys), ["en0", "awdl0", "en5"])
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

final class BatteryTests: XCTestCase {
    private let discharging: [String: Any] = [
        "Type": "InternalBattery", "Is Present": true, "Current Capacity": 23, "Max Capacity": 100,
        "Power Source State": "Battery Power", "Is Charging": false, "Time to Empty": 79, "Time to Full Charge": 0,
    ]

    func testReadsChargeAndTimeWhileDischarging() throws {
        let sample = try XCTUnwrap(BatterySample(description: discharging, registry: nil))
        XCTAssertEqual(sample.percent, 23)
        XCTAssertEqual(sample.state, .discharging)
        XCTAssertEqual(sample.minutesRemaining, 79)
        XCTAssertNil(sample.watts)
    }

    func testAccessoriesAreNotThisMacsBattery() {
        var hearingAid = discharging
        hearingAid["Type"] = "Accessory Source"
        XCTAssertNil(BatterySample(description: hearingAid, registry: nil))
        XCTAssertNil(BatterySample(description: [:], registry: nil))
    }

    func testEstimatingShowsNoTime() throws {
        var estimating = discharging
        estimating["Time to Empty"] = -1
        XCTAssertNil(try XCTUnwrap(BatterySample(description: estimating, registry: nil)).minutesRemaining)
    }

    func testPowerStates() throws {
        var power = discharging
        power["Power Source State"] = "AC Power"
        XCTAssertEqual(try XCTUnwrap(BatterySample(description: power, registry: nil)).state, .pluggedIn)
        power["Is Charged"] = true
        XCTAssertEqual(try XCTUnwrap(BatterySample(description: power, registry: nil)).state, .charged)
        power["Is Charged"] = false
        power["Is Charging"] = true
        power["Time to Full Charge"] = 45
        let charging = try XCTUnwrap(BatterySample(description: power, registry: nil))
        XCTAssertEqual(charging.state, .charging)
        XCTAssertEqual(charging.minutesRemaining, 45)
    }

    func testNegativeAmperageArrivingAsA64BitPattern() throws {
        // This is what ioreg shows for a 1081 mA discharge at 11.309 V.
        let registry: [String: Any] = ["Voltage": NSNumber(value: 11309),
                                       "Amperage": NSNumber(value: UInt64(18446744073709550535)),
                                       "CycleCount": NSNumber(value: 340)]
        let sample = try XCTUnwrap(BatterySample(description: discharging, registry: registry))
        XCTAssertEqual(try XCTUnwrap(sample.watts), 12.2, accuracy: 0.1)
        XCTAssertEqual(sample.cycleCount, 340)
    }

    func testSystemLoadIsPreferredOverTheBatterySideOfIt() throws {
        let registry: [String: Any] = ["Voltage": NSNumber(value: 11309), "Amperage": NSNumber(value: -1081),
                                       "PowerTelemetryData": ["SystemLoad": NSNumber(value: 13146)]]
        let sample = try XCTUnwrap(BatterySample(description: discharging, registry: registry))
        XCTAssertEqual(try XCTUnwrap(sample.watts), 13.146, accuracy: 0.001)
    }

    func testMenuBarDrawsNothingWithoutABattery() {
        let layout = MenuBarLayout.ladder(for: [.battery])[0]
        var snapshot = Snapshot()
        XCTAssertEqual(MenuBarReadout(layout: layout, snapshot: snapshot, thresholds: .init()).blocks.first?.rows, [])
        snapshot.battery = BatterySample(description: discharging, registry: nil)
        let rows = MenuBarReadout(layout: layout, snapshot: snapshot, thresholds: .init()).blocks.first?.rows
        XCTAssertEqual(rows?.first?.value, "23%")
    }

    func testThisMacsLiveReadingAgreesWithItself() {
        guard let sample = BatterySampler().sample() else { return } // desktops have none
        XCTAssertTrue((0...100).contains(sample.percent))
    }
}

final class CulpritTests: XCTestCase {
    private func app(_ name: String, pid: Int32, cpu: Double, memory: UInt64) -> ProcessInfoRow {
        ProcessInfoRow(pid: pid, started: 1, name: name, cpu: cpu, memory: memory,
                       app: ProcessApp(bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"), name: name))
    }

    /// The system reading a warning was raised on: `cores` cores, all at `total`.
    private func systemLoad(_ total: Double, cores: Int = 4) -> CPUSample {
        CPUSample(total: total, perCore: Array(repeating: total, count: cores))
    }

    func testNamesTheBiggestUserOfEachResource() {
        let sample = ProcessSample(rows: [app("Xcode", pid: 2, cpu: 1.8, memory: 1 << 30),
                                          app("Safari", pid: 3, cpu: 0.4, memory: 4 << 30)], state: .ready)
        XCTAssertEqual(sample.culprit(for: .cpu, cpu: systemLoad(0.8)), "Xcode 180%")
        XCTAssertEqual(sample.culprit(for: .memory, cpu: systemLoad(0.8)), "Safari 4.0 GB")
    }

    func testCommandLineToolsCount() {
        let sample = ProcessSample(rows: [ProcessInfoRow(pid: 9, started: 1, name: "yes", cpu: 2, memory: 1)], state: .ready)
        XCTAssertEqual(sample.culprit(for: .cpu, cpu: systemLoad(0.75)), "yes 200%")
    }

    func testDoesNotBlameABystander() {
        let quiet = ProcessSample(rows: [app("Notes", pid: 2, cpu: 0.03, memory: 1)], state: .ready)
        XCTAssertNil(quiet.culprit(for: .cpu, cpu: systemLoad(0.8)))
        XCTAssertNil(ProcessSample().culprit(for: .cpu, cpu: systemLoad(0.8)))
        XCTAssertNil(ProcessSample(rows: [app("Notes", pid: 2, cpu: 1, memory: 1)], state: .ready)
            .culprit(for: .disk, cpu: systemLoad(0.8)))
    }

    /// Ten cores at 80% is eight cores of work. Readable processes coming to a
    /// fraction of that puts the rest in processes this app cannot read, and
    /// the busiest readable one is then a bystander, even though it clears a
    /// quarter of a core.
    func testLoadTheListCannotSeeNamesNobody() {
        let busy = systemLoad(0.8, cores: 10)
        let bystanders = ProcessSample(rows: [app("Safari", pid: 2, cpu: 0.3, memory: 1),
                                              app("Slack", pid: 3, cpu: 0.2, memory: 1)], state: .ready)
        XCTAssertNil(bystanders.culprit(for: .cpu, cpu: busy))
        // A quarter of the load is a real part of it, whatever the rest is.
        let large = ProcessSample(rows: [app("Docker", pid: 2, cpu: 2.5, memory: 1)], state: .ready)
        XCTAssertEqual(large.culprit(for: .cpu, cpu: busy), "Docker 250%")
        // Work spread across processes that can be read still has a fair name.
        let build = ProcessSample(rows: (0..<8).map { index in
            ProcessInfoRow(pid: Int32(index + 2), started: 1, name: "clang", cpu: 0.6 - Double(index) / 100, memory: 1)
        }, state: .ready)
        XCTAssertEqual(build.culprit(for: .cpu, cpu: busy), "clang 60%")
    }

    /// The first scan after launch or wake has nothing to measure CPU against,
    /// but memory needs no baseline, so a memory warning raised on that scan
    /// still names the app.
    func testMemoryCulpritNeedsNoBaseline() {
        let sampler = ProcessSampler(read: { [.init(pid: 2, started: 1, cpuTime: 5, memory: 6 << 30),
                                               .init(pid: 3, started: 1, cpuTime: 5, memory: 1 << 30)] },
                                     clock: { 100 }, ticksToNanoseconds: 1,
                                     metadata: { pid in .init(name: pid == 2 ? "Safari" : "Notes", app: nil) })
        let first = sampler.sample()
        XCTAssertEqual(first.state, .sampling)
        XCTAssertEqual(first.culprit(for: .memory, cpu: systemLoad(0.8)), "Safari 6.0 GB")
        // CPU still waits for a second scan.
        XCTAssertNil(first.culprit(for: .cpu, cpu: systemLoad(0.8)))
    }

    func testTrackerReportsDwellThenRaiseAndKeepsTheCulprit() {
        var tracker = AttentionTracker()
        var snapshot = Snapshot()
        snapshot.cpu = CPUSample(total: 0.9, perCore: [0.9])
        XCTAssertEqual(tracker.update(snapshot: snapshot, thresholds: .init(), at: 100),
                       AttentionChange(dwellStarted: [.cpu]))
        XCTAssertEqual(tracker.update(snapshot: snapshot, thresholds: .init(), at: 105), AttentionChange())
        XCTAssertEqual(tracker.update(snapshot: snapshot, thresholds: .init(), at: 115),
                       AttentionChange(raised: [.cpu]))
        tracker.setCulprit("Xcode 180%", for: .cpu)
        XCTAssertEqual(tracker.update(snapshot: snapshot, thresholds: .init(), at: 116), AttentionChange())
        XCTAssertEqual(tracker.events.first?.culprit, "Xcode 180%")
    }

    func testEngineDoesNotScanWhileNothingIsWrong() {
        final class Counter: @unchecked Sendable { var reads = 0 }
        let counter = Counter()
        var clock = 0.0
        let sampler = ProcessSampler(read: {
            counter.reads += 1
            return [.init(pid: 7, started: 1, cpuTime: UInt64(counter.reads) * 1_000_000_000, memory: 1)]
        }, clock: { clock += 15; return clock }, ticksToNanoseconds: 1,
           metadata: { _ in .init(name: "busy", app: nil) })
        let engine = MetricsEngine(processSampler: sampler)
        engine.isTemperatureShown = { false }
        // Whatever else this machine is doing, no warning can start.
        var config = Config()
        config.thresholds.cpu = 1
        engine.configure(config)
        engine.start()
        engine.start()
        XCTAssertEqual(counter.reads, 0)
    }
}

final class ConfigStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VitalsConfigTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSaveRoundTripsAndDoesNotReportItselfAsAChange() throws {
        let folder = try directory()
        let store = ConfigStore(directory: folder)
        var changes = 0
        store.onChange = { _ in changes += 1 }
        var config = store.config
        config.menuBar = [.memory, .battery]
        config.sampleInterval = 2
        config.thresholds.cpu = 0.5
        XCTAssertTrue(store.save(config))
        XCTAssertEqual(store.config, config)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(ConfigStore(directory: folder).config, config)
    }

    func testSaveValidatesWhatItWrites() throws {
        let store = ConfigStore(directory: try directory())
        var config = store.config
        config.sampleInterval = 0.01
        XCTAssertTrue(store.save(config))
        XCTAssertEqual(store.config.sampleInterval, 0.5)
    }

    func testInvalidFileIsReportedAndNeverOverwritten() throws {
        let folder = try directory()
        let file = folder.appendingPathComponent("config.json")
        let broken = Data(#"{"menuBar": ["cpu",}"#.utf8)
        try broken.write(to: file)
        let store = ConfigStore(directory: folder)
        XCTAssertNotNil(store.problem)
        XCTAssertFalse(store.canSave)
        XCTAssertEqual(store.config, .default)
        XCTAssertFalse(store.save(.default))
        XCTAssertEqual(try Data(contentsOf: file), broken)
    }

    func testWrongTypeNamesTheKey() throws {
        let folder = try directory()
        try Data(#"{"sampleInterval":"fast"}"#.utf8).write(to: folder.appendingPathComponent("config.json"))
        XCTAssertTrue(try XCTUnwrap(ConfigStore(directory: folder).problem).contains("sampleInterval"))
    }

    func testUnknownMetricIsMentionedButStillLoadsAndSaves() throws {
        let folder = try directory()
        try Data(#"{"menuBar":["cpu","gpu"]}"#.utf8).write(to: folder.appendingPathComponent("config.json"))
        let store = ConfigStore(directory: folder)
        XCTAssertEqual(store.config.menuBar, [.cpu])
        XCTAssertTrue(try XCTUnwrap(store.problem).contains("gpu"))
        XCTAssertTrue(store.canSave)
        // Saving rewrites the list, so the notice has nothing left to report.
        XCTAssertTrue(store.save(store.config))
        XCTAssertNil(store.problem)
    }

    func testMetricListEditing() {
        var config = Config()
        config.menuBar = [.cpu, .memory]
        XCTAssertEqual(config.togglingMetric(.disk).menuBar, [.cpu, .memory, .disk])
        XCTAssertEqual(config.togglingMetric(.cpu).menuBar, [.memory])
        // The last metric stays: an empty menu bar has no way back.
        config.menuBar = [.cpu]
        XCTAssertEqual(config.togglingMetric(.cpu).menuBar, [.cpu])
        config.menuBar = [.cpu, .memory, .network]
        XCTAssertEqual(config.movingMetric(.network, by: -1).menuBar, [.cpu, .network, .memory])
        XCTAssertEqual(config.movingMetric(.cpu, by: -1).menuBar, [.cpu, .memory, .network])
        XCTAssertEqual(config.movingMetric(.network, by: 1).menuBar, [.cpu, .memory, .network])
    }
}

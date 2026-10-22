import AppKit
import XCTest
@testable import Vitals

final class ProcessRankingTests: XCTestCase {
    private func row(_ pid: Int32, name: String = "Helper", cpu: Double = 0, memory: UInt64 = 0,
                     path: String? = nil, started: UInt64 = 1) -> ProcessInfoRow {
        let app = path.map { ProcessApp(bundleURL: URL(fileURLWithPath: $0), name: "Browser") }
        return .init(pid: pid, started: started, name: name, cpu: cpu, memory: memory, app: app)
    }

    func testNestedHelpersResolveToOuterBundleWithoutGuessingOwnership() {
        XCTAssertEqual(ProcessApp.bundleURL(containing: URL(fileURLWithPath:
            "/Applications/Browser.app/Contents/Frameworks/Browser Helper.app/Contents/MacOS/Helper"))?.path,
                       "/Applications/Browser.app")
        XCTAssertEqual(ProcessApp.bundleURL(containing: URL(fileURLWithPath:
            "/Applications/Browser.app/Contents/XPCServices/Renderer.xpc/Contents/MacOS/Renderer"))?.path,
                       "/Applications/Browser.app")
        XCTAssertNil(ProcessApp.bundleURL(containing: URL(fileURLWithPath: "/usr/local/bin/browser-helper")))
        XCTAssertNil(ProcessApp.bundleURL(containing: URL(fileURLWithPath: "/usr/local/bin/tool.app")))
    }

    func testAggregationPrecedesRankingAndIncludesEveryHelper() throws {
        let rows = (1...6).map { row(Int32($0), cpu: 0.3, memory: 100, path: "/Applications/Browser.app") }
            + [row(7, name: "Busy", cpu: 1.0, memory: 500)]
        let sample = ProcessSample(rows: rows, state: .ready)
        let group = try XCTUnwrap(sample.ranked(by: .cpu, filter: .all).first)
        XCTAssertEqual(group.name, "Browser")
        XCTAssertEqual(group.processes.count, 6)
        XCTAssertEqual(group.cpu, 1.8, accuracy: 0.00001)
        XCTAssertEqual(group.memory, 600)
        XCTAssertEqual(Format.percent(group.cpu), "180%")
        XCTAssertEqual(sample.ranked(by: .memory, filter: .all).first?.id, group.id)
        XCTAssertEqual(sample.topByCPU.first?.pid, 7)
        XCTAssertEqual(sample.topByCPU.count, 5)
        XCTAssertEqual(sample.rows.count, 7)
    }

    func testAppsFilterExcludesUnresolvedProcessesAndSeparatesInstallations() {
        let sample = ProcessSample(rows: [
            row(1, path: "/Applications/Browser.app"),
            row(2, path: "/Users/test/Applications/Browser.app"),
            row(3, name: "Browser Helper", cpu: 2),
            row(4, name: "Browser Helper", cpu: 1)
        ], state: .ready)
        XCTAssertEqual(sample.ranked(by: .cpu, filter: .apps).count, 2)
        let all = sample.ranked(by: .cpu, filter: .all)
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(all.first?.processes.first?.pid, 3)
        XCTAssertNotEqual(all[0].id, all[1].id)
    }

    func testSortingAndTiesAreDeterministic() {
        let rows = [row(5, name: "Z", cpu: 1, memory: 10),
                    row(3, name: "A", cpu: 1, memory: 20),
                    row(2, name: "A", cpu: 1, memory: 30)]
        XCTAssertEqual(ProcessSort.cpu.sorted(rows).map(\.pid), [2, 3, 5])
        XCTAssertEqual(ProcessSort.memory.sorted(rows).map(\.pid), [2, 3, 5])
        for sort in ProcessSort.allCases {
            let forward = ProcessSample(rows: rows, state: .ready).ranked(by: sort, filter: .all)
            let backward = ProcessSample(rows: rows.reversed(), state: .ready).ranked(by: sort, filter: .all)
            XCTAssertEqual(forward.map(\.id), backward.map(\.id))
        }
        let sample = ProcessSample(rows: [row(1, cpu: 2, memory: 10), row(2, cpu: 1, memory: 20)], state: .ready)
        XCTAssertEqual(sample.ranked(by: .cpu, filter: .all).first?.processes.first?.pid, 1)
        XCTAssertEqual(sample.ranked(by: .memory, filter: .all).first?.processes.first?.pid, 2)
    }

    func testShowAllExpansionAndProcessIdentityAcrossUpdates() throws {
        let rows = (1...8).map { row(Int32($0), path: "/Applications/App\($0).app") }
        var selection = ProcessListSelection()
        let sample = ProcessSample(rows: rows, state: .ready)
        XCTAssertEqual(selection.sort, .cpu)
        XCTAssertEqual(selection.filter, .apps)
        XCTAssertEqual(selection.displayed(in: sample).count, 5)
        let id = try XCTUnwrap(selection.displayed(in: sample).first?.id)
        selection.expanded.insert(id)
        selection.sort = .memory
        selection.filter = .all
        selection.showAll = true
        selection.retainLiveGroups(in: sample)
        XCTAssertEqual(selection.displayed(in: sample).count, 8)
        XCTAssertTrue(selection.expanded.contains(id))
        selection.retainLiveGroups(in: ProcessSample(state: .unavailable))
        XCTAssertTrue(selection.expanded.contains(id))
        selection.showAll = false
        XCTAssertEqual(selection.displayed(in: sample).count, 5)
        selection.retainLiveGroups(in: ProcessSample(rows: [], state: .ready))
        XCTAssertTrue(selection.expanded.isEmpty)
        XCTAssertNotEqual(row(1, started: 1).id, row(1, started: 2).id)
    }

    func testSamplerBaselinesCachingPIDReuseAndExits() throws {
        var time = 100.0
        var input: [ProcessSampler.Reading]? = [.init(pid: 1, started: 10, cpuTime: 1_000, memory: 20)]
        var resolutions = 0
        let sampler = ProcessSampler(read: { input }, clock: { time }, ticksToNanoseconds: 1,
                                     metadata: { _ in
            resolutions += 1
            return .init(name: "Name \(resolutions)", app: nil)
        })
        XCTAssertEqual(sampler.sample().state, .sampling)
        input?[0].cpuTime += 1_500_000_000
        time += 1
        let ready = sampler.sample()
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(try XCTUnwrap(ready.rows.first).cpu, 1.5, accuracy: 0.00001)
        XCTAssertEqual(resolutions, 1)

        // The same PID with a new start time gets new metadata and no old CPU.
        input = [.init(pid: 1, started: 20, cpuTime: 10, memory: 30)]
        time += 1
        let reused = sampler.sample()
        XCTAssertEqual(reused.rows.first?.name, "Name 2")
        XCTAssertEqual(reused.rows.first?.cpu, 0)
        XCTAssertNotEqual(ready.rows.first?.id, reused.rows.first?.id)
        input = []
        time += 1
        let empty = sampler.sample()
        XCTAssertEqual(empty.state, .ready)
        XCTAssertTrue(empty.groups.isEmpty)
        input = [.init(pid: 1, started: 20, cpuTime: 100, memory: 30)]
        time += 1
        XCTAssertEqual(sampler.sample().rows.first?.name, "Name 3")

        // Reopen and failure recovery require a fresh interval, not stale data.
        sampler.resetBaseline()
        time += 100
        XCTAssertEqual(sampler.sample().state, .sampling)
        time += 1
        XCTAssertEqual(sampler.sample().state, .ready)
        input = nil
        XCTAssertEqual(sampler.sample().state, .unavailable)
        input = [.init(pid: 1, started: 20, cpuTime: 50, memory: 30)]
        time += 1
        XCTAssertEqual(sampler.sample().state, .sampling)
        input?[0].cpuTime = 10 // A regressing counter never underflows.
        time += 1
        XCTAssertEqual(sampler.sample().rows.first?.cpu, 0)
    }

    @MainActor
    func testEngineOnlyScansVisibleDetailAndRebaselinesAfterWake() {
        var reads = 0
        var time = 100.0
        let sampler = ProcessSampler(read: { reads += 1; return [] }, clock: { time }, ticksToNanoseconds: 1)
        let engine = MetricsEngine(processSampler: sampler)
        var visible = false
        engine.isDetailVisible = { visible }
        engine.isTemperatureShown = { false }
        engine.start()
        XCTAssertEqual(reads, 0)
        engine.prepareDetailSamplers()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(engine.snapshot.processes.state, .sampling)
        visible = true
        time += 1
        engine.start()
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(engine.snapshot.processes.state, .ready)
        visible = false
        time += 100
        engine.start()
        XCTAssertEqual(reads, 2)
        engine.prepareDetailSamplers()
        XCTAssertEqual(engine.snapshot.processes.state, .sampling)
        visible = true
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertEqual(engine.snapshot.processes.state, .sampling)
        let beforeWake = reads
        time += 100
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(reads, beforeWake + 1)
        XCTAssertEqual(engine.snapshot.processes.state, .sampling)
        time += 1
        engine.start()
        XCTAssertEqual(engine.snapshot.processes.state, .ready)
    }
}

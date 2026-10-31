import AppKit
import SwiftUI
import XCTest
@testable import Vitals

/// Optional offscreen render for visual review; does not launch or control the
/// installed application. VITALS_RENDER_DIR selects the output directory.
final class PreviewTests: XCTestCase {
    @MainActor
    func testRenderPopover() async throws {
        guard let directory = ProcessInfo.processInfo.environment["VITALS_RENDER_DIR"] else {
            throw XCTSkip("Set VITALS_RENDER_DIR for offscreen visual review")
        }
        _ = NSApplication.shared
        var snapshot = Snapshot()
        let now = Date().timeIntervalSince1970
        snapshot.sampledAt = now
        snapshot.cpu = CPUSample(total: 0.32, user: 0.2, system: 0.12, perCore: [0.8, 0.6, 0.3, 0.4, 0.1, 0.2, 0.1, 0.1, 0.2, 0.1])
        snapshot.memory = MemorySample(total: 24 << 30, used: 16 << 30, app: 10 << 30,
                                       wired: 3 << 30, compressed: 3 << 30, swapUsed: 600 << 20)
        snapshot.network = NetworkSample(download: 2_000_000, upload: 40_000, sessionReceived: 800 << 20, interface: "en0", ipAddress: "192.0.2.1")
        snapshot.disk = DiskSample(read: 20_000, write: 500_000, free: 28 << 30, total: 460 << 30)
        snapshot.thermal = ThermalSample(cpu: 44, cpuAverage: 39, ssd: 31, battery: 27)
        for seconds in stride(from: 300, through: 0, by: -1) {
            if (100...130).contains(seconds) { continue }
            let value = 0.2 + 0.12 * sin(Double(seconds) / 14)
            snapshot.cpuHistory.append(value, at: now - Double(seconds), interval: 1)
            snapshot.memoryHistory.append(0.66 + value / 10, at: now - Double(seconds), interval: 1)
            snapshot.downloadHistory.append(value * 10_000_000, at: now - Double(seconds), interval: 1)
            snapshot.uploadHistory.append(value * 200_000, at: now - Double(seconds), interval: 1)
            snapshot.diskReadHistory.append(value * 300_000, at: now - Double(seconds), interval: 1)
            snapshot.diskWriteHistory.append((1 - value) * 900_000, at: now - Double(seconds), interval: 1)
        }
        snapshot.attention = [AttentionEvent(kind: .disk, title: "Disk space is low", detail: "28.0 GB available · below 10%", startedAt: now - 60),
                              AttentionEvent(kind: .cpu, title: "CPU use remains high", detail: "82% overall · at or above 70%", startedAt: now - 900, endedAt: now - 480)]
        snapshot.processes = processFixture()
        let engine = MetricsEngine(initialSnapshot: snapshot)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for tab in PanelTab.allCases {
            UserDefaults.standard.set(tab.rawValue, forKey: "panel.tab")
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                let view = NSHostingView(rootView: PopoverView(engine: engine, maxHeight: 2000).background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96)).environment(\.colorScheme, scheme))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 1400), styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = view
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                // Two passes: the panel measures itself and then takes that height.
                for _ in 0..<3 {
                    view.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(100))
                    view.setFrameSize(view.fittingSize)
                }
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("popover-\(tab.rawValue.lowercased())-\(name).png"))
                window.contentView = nil
            }
        }
        UserDefaults.standard.removeObject(forKey: "panel.tab")
    }

    /// Focused variants keep the expandable rows visible in offscreen review.
    @MainActor
    func testRenderTopApps() async throws {
        guard let directory = ProcessInfo.processInfo.environment["VITALS_RENDER_DIR"] else {
            throw XCTSkip("Set VITALS_RENDER_DIR for offscreen visual review")
        }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let sample = processFixture()
        let expanded = Set(sample.groups.filter { $0.name == "Safari" }.map(\.id))
        let variants: [(String, ProcessSample, ProcessListSelection)] = [
            ("default", sample, .init()),
            ("expanded", sample, .init(expanded: expanded)),
            ("all-memory", sample, .init(sort: .memory, filter: .all, showAll: true)),
            ("sampling", ProcessSample(), .init()),
            ("unavailable", ProcessSample(state: .unavailable), .init()),
            ("empty", ProcessSample(rows: [], state: .ready), .init())
        ]
        for (name, sample, selection) in variants {
            for (theme, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                let view = NSHostingView(rootView: TopAppsView(sample: sample, selection: selection)
                    .font(.system(size: 11).monospacedDigit())
                    .padding(14)
                    .frame(width: 360, alignment: .topLeading)
                    .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
                    .environment(\.colorScheme, scheme))
                view.frame = NSRect(origin: .zero, size: view.fittingSize)
                let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = view
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("apps-\(name)-\(theme).png"))
                window.contentView = nil
            }
        }
    }

    private func processFixture() -> ProcessSample {
        let safari = ProcessApp(bundleURL: URL(fileURLWithPath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"), name: "Safari")
        let notes = ProcessApp(bundleURL: URL(fileURLWithPath: "/System/Applications/Notes.app"), name: "Notes")
        let long = ProcessApp(bundleURL: URL(fileURLWithPath: "/Applications/Long.app"), name: "An app with a particularly long display name")
        var rows: [ProcessInfoRow] = [
            .init(pid: 1, started: 1, name: "Safari", cpu: 0.4, memory: 300 << 20, app: safari),
            .init(pid: 2, started: 1, name: "com.apple.WebKit.WebContent", cpu: 1.2, memory: 600 << 20, app: safari),
            .init(pid: 3, started: 1, name: "Notes", cpu: 0.1, memory: 200 << 20, app: notes),
            .init(pid: 4, started: 1, name: "WindowServer", cpu: 0.2, memory: 2 << 30),
            .init(pid: 5, started: 1, name: "Long app helper with a particularly long process name", cpu: 0.08, memory: 100 << 20, app: long)
        ]
        for index in 6...9 {
            let app = ProcessApp(bundleURL: URL(fileURLWithPath: "/Applications/Example\(index).app"), name: "Example \(index)")
            rows.append(.init(pid: Int32(index), started: 1, name: app.name, cpu: 0.01, memory: 50 << 20, app: app))
        }
        return ProcessSample(rows: rows, state: .ready)
    }
}

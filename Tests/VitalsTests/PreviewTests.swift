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
        }
        snapshot.attention = [AttentionEvent(kind: .disk, title: "Disk space is low", detail: "28.0 GB available · below 10%", startedAt: now - 60)]
        snapshot.processes = ProcessSample(
            topByCPU: [.init(id: 1, name: "Codex (Renderer)", cpu: 0.32, memory: 600 << 20)],
            topByMemory: [.init(id: 1, name: "Codex (Renderer)", cpu: 0.32, memory: 600 << 20)])
        let engine = MetricsEngine(initialSnapshot: snapshot)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let view = NSHostingView(rootView: PopoverView(engine: engine).background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96)).environment(\.colorScheme, scheme))
            view.frame = NSRect(x: 0, y: 0, width: 360, height: 700)
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("popover-\(name).png"))
            window.contentView = nil
        }
    }
}

import AppKit
import Combine
import Foundation

/// Everything the UI draws, in one value type.
///
/// `Equatable` so SwiftUI can skip redraws when nothing material changed —
/// which is most ticks, since CPU rounds to the same integer percent for
/// seconds at a time.
struct Snapshot: Equatable {
    var cpu = CPUSample()
    var memory = MemorySample()
    var network = NetworkSample()
    var disk = DiskSample()
    var thermal = ThermalSample()
    var processes = ProcessSample()

    var cpuHistory = RingBuffer(capacity: 60)
    var memoryHistory = RingBuffer(capacity: 60)
    var downloadHistory = RingBuffer(capacity: 60)
    var uploadHistory = RingBuffer(capacity: 60)
    var diskReadHistory = RingBuffer(capacity: 60)
    var diskWriteHistory = RingBuffer(capacity: 60)
}

/// Owns the one timer in the app and fans it out to the samplers.
///
/// Design constraints, all of them aimed at not being another monitor that
/// costs more battery than it saves:
///   - exactly one timer, generous tolerance so macOS coalesces our wakeups
///     with other system timers rather than waking the CPU on its own
///   - sampling stops entirely when the machine or its display sleeps
///   - expensive samplers are demand-driven, running only while the popover
///     is actually on screen
final class MetricsEngine: ObservableObject {
    @Published private(set) var snapshot = Snapshot()

    private let cpuSampler = CPUSampler()
    private let memorySampler = MemorySampler()
    private let networkSampler = NetworkSampler()
    private let diskSampler = DiskSampler()
    private let thermalSampler = ThermalSampler()
    private let processSampler = ProcessSampler()

    /// Seconds between temperature reads at full speed.
    ///
    /// Deliberately a duration rather than a count of ticks. Reading the
    /// sensors is by far the most expensive thing this app does — one IOKit
    /// event copy per sensor, and there are three dozen — and temperature
    /// moves slowly enough that it does not need the base rate. Tying it to a
    /// tick count instead would mean doubling the sample rate also doubles how
    /// often the costliest sampler runs, so a 2x faster readout would cost
    /// well over 2x the CPU.
    private let baseThermalInterval: TimeInterval = 16
    private var lastThermalSample: TimeInterval = 0

    private var timer: Timer?
    private var isSuspended = false

    /// Whether the detail panel is on screen, so its expensive samplers can be
    /// skipped when it is not.
    ///
    /// This asks the popover directly rather than tracking a flag that gets
    /// set on open and cleared on close. A flag has to be cleared by every
    /// path that can dismiss a popover — clicking away, another app taking
    /// focus, the window closing — and missing one leaves it stuck true, which
    /// silently makes the app walk the entire process table every two seconds
    /// forever. Asking the source of truth cannot desynchronise.
    var isDetailVisible: () -> Bool = { false }

    /// Whether temperature is on display in the menu bar. Reading the sensors
    /// is the single most expensive thing this app does — one IOKit event copy
    /// per sensor, and there are three dozen — so it is skipped entirely when
    /// the metric is not configured and the detail panel is closed.
    var isTemperatureShown: () -> Bool = { true }

    /// Primes the per-process CPU baseline so the first visible reading is a
    /// real delta rather than a column of zeros. Called when the panel opens.
    func prepareDetailSamplers() {
        _ = processSampler.sample()
    }

    /// The rate asked for in the config file.
    private(set) var configuredInterval: TimeInterval

    /// Everything slows by this factor while the machine is in Low Power Mode.
    ///
    /// Low Power Mode is the user saying "stop spending battery on things that
    /// are not the task at hand", and a monitor polling twice a second is
    /// exactly that. Halving the rate keeps the readout live while roughly
    /// halving what it costs.
    private static let lowPowerFactor: Double = 2

    private var isLowPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// The rate actually used, after the Low Power Mode adjustment.
    var effectiveInterval: TimeInterval {
        isLowPower ? configuredInterval * Self.lowPowerFactor : configuredInterval
    }

    private var thermalInterval: TimeInterval {
        isLowPower ? baseThermalInterval * Self.lowPowerFactor : baseThermalInterval
    }

    var performanceCoreCount: Int { cpuSampler.performanceCoreCount }
    var efficiencyCoreCount: Int { cpuSampler.efficiencyCoreCount }

    init(interval: TimeInterval = 1.0) {
        self.configuredInterval = interval
        observePowerNotifications()
    }

    deinit {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Lifecycle

    func start() {
        timer?.invalidate()

        let interval = effectiveInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // Half the interval of slack lets the kernel batch this wakeup with
        // whatever else is already scheduled. This is the single biggest
        // energy win available to a polling menu bar app.
        timer.tolerance = interval / 2

        // .common rather than .default: while a popover or menu is tracking,
        // the run loop leaves default mode and a default-mode timer silently
        // stops firing — the numbers would freeze exactly when being read.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Prime the tick counters so the first visible sample is a real delta
        // rather than a zero.
        tick()
    }

    func setInterval(_ newValue: TimeInterval) {
        let clamped = min(max(newValue, 0.5), 60)
        guard clamped != configuredInterval else { return }
        configuredInterval = clamped
        if timer != nil { start() }
    }

    /// Rebuilds the timer when the machine enters or leaves Low Power Mode.
    private func powerStateChanged() {
        guard timer != nil else { return }
        start()
    }

    private func suspend() {
        isSuspended = true
        timer?.invalidate()
        timer = nil
    }

    private func resume() {
        guard isSuspended else { return }
        isSuspended = false
        start()
    }

    private func observePowerNotifications() {
        // Low Power Mode toggling is posted by ProcessInfo, not NSWorkspace.
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.powerStateChanged() }

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.suspend() }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.resume() }
        }
    }

    // MARK: - Sampling

    private func tick() {
        var next = snapshot

        if let cpu = cpuSampler.sample() {
            next.cpu = cpu
            next.cpuHistory.append(cpu.total)
        }

        if let memory = memorySampler.sample() {
            next.memory = memory
            next.memoryHistory.append(memory.pressure)
        }

        if let network = networkSampler.sample() {
            next.network = network
            next.downloadHistory.append(network.download)
            next.uploadHistory.append(network.upload)
        }

        if let disk = diskSampler.sample() {
            next.disk = disk
            next.diskReadHistory.append(disk.read)
            next.diskWriteHistory.append(disk.write)
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastThermalSample >= thermalInterval,
           isTemperatureShown() || isDetailVisible() {
            next.thermal = thermalSampler.sample()
            lastThermalSample = now
        }

        // Walking the process table is the most expensive thing here, so it
        // happens only while someone is actually reading the result.
        if isDetailVisible(), let processes = processSampler.sample() {
            next.processes = processes
        }

        // Assigning an unchanged value still fires objectWillChange, so guard
        // it: an idle machine produces identical snapshots for many ticks in
        // a row and there is no reason to re-render for those.
        if next != snapshot {
            snapshot = next
        }
    }
}

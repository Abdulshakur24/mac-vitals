import AppKit
import Combine
import Foundation

/// Everything the UI draws, in one value type.
///
/// Values and timestamped history are published together on the existing tick;
/// the popover observes a consistent sample without a separate chart timer.
struct Snapshot: Equatable {
    var cpu = CPUSample()
    var memory = MemorySample()
    var network = NetworkSample()
    var disk = DiskSample()
    var thermal = ThermalSample()
    var processes = ProcessSample()

    var cpuHistory = MetricHistory()
    var memoryHistory = MetricHistory()
    var downloadHistory = MetricHistory()
    var uploadHistory = MetricHistory()
    var diskReadHistory = MetricHistory()
    var diskWriteHistory = MetricHistory()
    var sampledAt: TimeInterval = 0
    var attention: [AttentionEvent] = []

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
    @Published private(set) var thresholds = Config.Thresholds()
    private var attentionTracker = AttentionTracker()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func configure(_ config: Config) {
        let validated = config.validated()
        let thresholdsChanged = thresholds != validated.thresholds
        let intervalChanged = configuredInterval != validated.sampleInterval
        if thresholdsChanged {
            thresholds = validated.thresholds
            attentionTracker.interrupt(at: Date().timeIntervalSince1970)
        }
        setInterval(validated.sampleInterval)
        // setInterval already samples when it rebuilds a running timer.
        if thresholdsChanged, !intervalChanged, timer != nil { tick() }
    }

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

    init(interval: TimeInterval = 1.0, initialSnapshot: Snapshot = Snapshot()) {
        self.snapshot = initialSnapshot
        self.configuredInterval = interval
        observePowerNotifications()
    }

    deinit {
        timer?.invalidate()
        for (center, token) in observers { center.removeObserver(token) }
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
        snapshot.cpuHistory.markGap()
        snapshot.memoryHistory.markGap()
        snapshot.downloadHistory.markGap()
        snapshot.uploadHistory.markGap()
        snapshot.diskReadHistory.markGap()
        snapshot.diskWriteHistory.markGap()
        attentionTracker.interrupt(at: Date().timeIntervalSince1970)
        timer?.invalidate()
        timer = nil
    }

    private func resume() {
        guard isSuspended else { return }
        isSuspended = false
        cpuSampler.resetBaseline()
        networkSampler.resetBaseline()
        diskSampler.resetBaseline()
        lastThermalSample = 0
        start()
    }

    private func observePowerNotifications() {
        // Low Power Mode toggling is posted by ProcessInfo, not NSWorkspace.
        let powerToken = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.powerStateChanged() }

        observers.append((NotificationCenter.default, powerToken))

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            let token = center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.suspend() }
            observers.append((center, token))
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            let token = center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.resume() }
            observers.append((center, token))
        }
    }

    // MARK: - Sampling

    private func tick() {
        var next = snapshot
        let timestamp = Date().timeIntervalSince1970
        if snapshot.sampledAt > 0, timestamp - snapshot.sampledAt > effectiveInterval * 2 + 5 || timestamp < snapshot.sampledAt {
            attentionTracker.interrupt(at: snapshot.sampledAt)
        }
        next.sampledAt = timestamp

        let cpuSample = cpuSampler.sample()
        if let cpu = cpuSample {
            next.cpu = cpu
            next.cpuHistory.append(cpu.total, at: timestamp, interval: effectiveInterval)
        }

        let memorySample = memorySampler.sample()
        if let memory = memorySample {
            next.memory = memory
            next.memoryHistory.append(memory.usedFraction, at: timestamp, interval: effectiveInterval)
        }

        if let network = networkSampler.sample() {
            next.network = network
            next.downloadHistory.append(network.download, at: timestamp, interval: effectiveInterval)
            next.uploadHistory.append(network.upload, at: timestamp, interval: effectiveInterval)
        } else {
            next.downloadHistory.markGap()
            next.uploadHistory.markGap()
        }

        let diskSample = diskSampler.sample()
        if let disk = diskSample {
            next.disk = disk
            next.diskReadHistory.append(disk.read, at: timestamp, interval: effectiveInterval)
            next.diskWriteHistory.append(disk.write, at: timestamp, interval: effectiveInterval)
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastThermalSample >= thermalInterval,
           isTemperatureShown() || isDetailVisible() {
            next.thermal = thermalSampler.sample()
            lastThermalSample = now
        }

        // Public thermal state remains available without temperature sensors.
        next.thermal.state = ProcessInfo.processInfo.thermalState
        // A failed sample must not sustain a warning using an old reading.
        var evidence = next
        if cpuSample == nil { evidence.cpu = CPUSample(); next.cpuHistory.markGap() }
        if memorySample == nil { evidence.memory = MemorySample(); next.memoryHistory.markGap() }
        if diskSample == nil {
            evidence.disk = DiskSample()
            next.diskReadHistory.markGap()
            next.diskWriteHistory.markGap()
        }
        attentionTracker.update(snapshot: evidence, thresholds: thresholds, at: timestamp)
        next.attention = attentionTracker.events

        // Walking the process table is the most expensive thing here, so it
        // happens only while someone is actually reading the result.
        if isDetailVisible(), let processes = processSampler.sample() {
            next.processes = processes
        }

        // Publish the readings, history timestamp, and attention state together.
        if next != snapshot {
            snapshot = next
        }
    }
}

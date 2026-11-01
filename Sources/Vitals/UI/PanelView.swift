import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case apps = "Apps", history = "History"
    var id: Self { self }
}

/// What the app needs to tell a panel it may not have built yet. The gear menu
/// lives in AppKit, and its Settings item works whether the panel is open or not.
final class PanelState: ObservableObject {
    @Published var showsSettings = false
}

/// The detail panel shown when the status item is clicked.
///
/// Laid out like Control Center: separate glass modules floating on nothing,
/// with no sheet behind them. The readings and any warning are always in view,
/// and one large module holds whichever of the two longer lists is wanted. The
/// panel takes the height of what it is showing and scrolls past `maxHeight`.
struct PanelView: View {
    @ObservedObject var engine: MetricsEngine
    @ObservedObject var config: ConfigStore
    @ObservedObject var panel: PanelState
    /// Tallest the panel may be on the display it opened on.
    var maxHeight: CGFloat = 700
    /// Opens the same menu as right-clicking the status item.
    var showMenu: () -> Void = {}
    /// Opens the config file for editing.
    var editConfig: () -> Void = {}

    @AppStorage("panel.tab") private var tab: PanelTab = .apps
    @AppStorage("panel.historyHour") private var showsHour = false
    @State private var showRecent = false
    @State private var scrollTarget: HistorySection?
    @State private var chromeHeight: CGFloat = 200
    @State private var contentHeight: CGFloat = 320

    private var snapshot: Snapshot { engine.snapshot }
    private var historyWindow: HistoryWindow { showsHour ? .oneHour : .fiveMinutes }
    private var activeWarnings: [AttentionEvent] { snapshot.attention.filter { $0.endedAt == nil } }

    var body: some View {
        GlassGroup {
            if panel.showsSettings {
                SettingsView(store: config, editConfig: editConfig) { panel.showsSettings = false }
                    .glassModule(in: RoundedRectangle(cornerRadius: Self.cornerRadius), blur: 1)
            } else {
                dashboard
            }
        }
        .frame(width: 348)
        .padding(6)
        .font(.system(size: 11).monospacedDigit())
    }

    private static let cornerRadius: CGFloat = 28

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 8) {
            modules.onGeometryChange(for: CGFloat.self, of: \.size.height) { chromeHeight = $0 + 8 + 50 }
            VStack(spacing: 0) {
                tabBar
                divider
                ScrollViewReader { proxy in
                    ScrollView {
                        tabContent
                            .onGeometryChange(for: CGFloat.self, of: \.size.height) { contentHeight = $0 }
                    }
                    .frame(height: min(contentHeight, max(160, maxHeight - chromeHeight)))
                    .task(id: scrollTarget) {
                        guard let scrollTarget else { return }
                        // The History tab may be appearing in this same update, and
                        // a section that is not laid out yet cannot be scrolled to.
                        await Task.yield()
                        proxy.scrollTo(scrollTarget, anchor: .top)
                        self.scrollTarget = nil
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            .glassModule(in: RoundedRectangle(cornerRadius: Self.cornerRadius), blur: 1)
        }
    }

    private var modules: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlanceModules(tiles: tiles, bars: bars, end: snapshot.sampledAt, duration: HistoryWindow.fiveMinutes.rawValue) { section in
                tab = .history
                scrollTarget = section
            }
            if !activeWarnings.isEmpty { warnings }
            if let problem = config.problem { configProblem(problem) }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 10) {
            Picker("Panel view", selection: $tab) {
                ForEach(PanelTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            Spacer()
            if ProcessInfo.processInfo.isLowPowerModeEnabled {
                Image(systemName: "leaf")
                    .foregroundStyle(.secondary)
                    .help("Low Power Mode doubles the sample interval")
                    .accessibilityLabel("Low Power Mode")
            }
            Button(action: showMenu) {
                Image(systemName: "gearshape").font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings and more")
            .accessibilityLabel("Vitals menu")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var tiles: [GlanceTile] {
        var tiles = [
            GlanceTile(id: .cpu, title: "CPU", value: Format.percent(snapshot.cpu.total), symbol: "cpu",
                       isAlert: snapshot.cpu.total >= engine.thresholds.cpu,
                       sparkline: points(snapshot.cpuHistory, .fiveMinutes)),
            GlanceTile(id: .network, title: "Network", value: "↑ \(Format.rate(snapshot.network.upload))",
                       symbol: "arrow.up.arrow.down",
                       titleOverride: "↓ \(Format.rate(snapshot.network.download))",
                       spokenValue: "\(Format.rate(snapshot.network.download)) down, \(Format.rate(snapshot.network.upload)) up"),
        ]
        if let temperature = snapshot.thermal.cpu {
            tiles.append(GlanceTile(id: .temperature, title: "Temperature", value: Format.celsius(temperature),
                                    symbol: "thermometer.medium",
                                    caption: snapshot.thermal.state == .nominal ? nil : thermalStateLabel,
                                    isAlert: temperature >= engine.thresholds.temperature || snapshot.thermal.state.rawValue >= ProcessInfo.ThermalState.serious.rawValue,
                                    spokenValue: "\(Int(temperature.rounded())) degrees"))
        }
        if let battery = snapshot.battery {
            tiles.append(GlanceTile(id: .battery, title: "Battery", value: "\(battery.percent)%",
                                    symbol: batterySymbol(battery),
                                    caption: batteryCaption(battery), isAlert: battery.isLow))
        }
        return tiles
    }

    private var bars: [GlanceBar] {
        [
            GlanceBar(id: .memory, title: "Memory",
                      value: "\(Format.bytes(snapshot.memory.used)) of \(Format.bytes(snapshot.memory.total))",
                      fraction: snapshot.memory.usedFraction, symbol: "memorychip",
                      isAlert: snapshot.memory.pressureLevel > 1),
            GlanceBar(id: .disk, title: "Disk",
                      value: "\(Format.bytes(snapshot.disk.free)) free of \(Format.bytes(snapshot.disk.total))",
                      fraction: snapshot.disk.usedFraction, symbol: "internaldrive",
                      isAlert: snapshot.disk.total > 0 && snapshot.disk.freeFraction < engine.thresholds.diskFree),
        ]
    }

    private func batterySymbol(_ battery: BatterySample) -> String {
        if battery.state == .charging { return "battery.100percent.bolt" }
        return switch battery.percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private var warnings: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(activeWarnings) { event in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title).fontWeight(.semibold)
                        Text(event.detail).foregroundStyle(.secondary)
                        if let culprit = event.culprit { Text("Top: \(culprit)").fontWeight(.medium) }
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassModule(in: RoundedRectangle(cornerRadius: 24), tint: .orange.opacity(0.35))
    }

    private func configProblem(_ problem: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("config.json: \(problem)").fontWeight(.semibold)
                if !config.canSave { Text("Using the last good settings").foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            Button("Open", action: editConfig).controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassModule(in: RoundedRectangle(cornerRadius: 24), tint: .orange.opacity(0.35))
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .apps:
            section { TopAppsView(sample: snapshot.processes, selection: .saved()) }
        case .history:
            VStack(alignment: .leading, spacing: 0) {
                section { historyControls }
                divider
                section { cpu }.id(HistorySection.cpu)
                divider
                section { memory }.id(HistorySection.memory)
                divider
                section { network }.id(HistorySection.network)
                divider
                section { disk }.id(HistorySection.disk)
                if snapshot.thermal.cpu != nil || snapshot.thermal.state != .nominal {
                    divider
                    section { temperature }.id(HistorySection.temperature)
                }
                if let battery = snapshot.battery {
                    divider
                    section { self.battery(battery) }.id(HistorySection.battery)
                }
            }
        }
    }

    private var historyControls: some View {
        let recent = snapshot.attention.filter { $0.endedAt != nil }.reversed()
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last").foregroundStyle(.secondary)
                Picker("History window", selection: $showsHour) {
                    ForEach(HistoryWindow.allCases) { window in
                        Text(window.label).tag(window == .oneHour)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 128)
                Spacer(minLength: 0)
            }
            .help("Five-second peaks. Gaps are time asleep or closed.")
            if !recent.isEmpty {
                DisclosureGroup("Recent warnings (\(recent.count))", isExpanded: $showRecent) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(recent)) { event in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.title)
                                Text(eventSpan(event)).foregroundStyle(.secondary)
                                Text(event.detail).foregroundStyle(.secondary)
                                if let culprit = event.culprit {
                                    Text("Top: \(culprit)").foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    /// `14:02–14:09 · 7 min`
    private func eventSpan(_ event: AttentionEvent) -> String {
        let end = event.endedAt ?? snapshot.sampledAt
        let clock = Date.FormatStyle(date: .omitted, time: .shortened)
        let start = Date(timeIntervalSince1970: event.startedAt).formatted(clock)
        return "\(start)–\(Date(timeIntervalSince1970: end).formatted(clock)) · \(Format.duration(end - event.startedAt))"
    }

    private func points(_ history: MetricHistory, _ window: HistoryWindow? = nil) -> [HistoryPoint] {
        history.points(endingAt: snapshot.sampledAt, duration: (window ?? historyWindow).rawValue)
    }

    private func chart(_ series: [HistorySeries], ceiling: Double, summary: String) -> some View {
        HistoryChart(series: series, end: snapshot.sampledAt, duration: historyWindow.rawValue,
                     ceiling: ceiling, summary: summary)
    }

    /// Scale for a rate chart: the busiest moment in view, whichever series.
    private func ceiling(_ series: [[HistoryPoint]]) -> Double {
        max(1, series.compactMap(\.peak).max() ?? 0)
    }

    // MARK: - Sections

    private var cpu: some View {
        let history = points(snapshot.cpuHistory)
        return VStack(alignment: .leading, spacing: 8) {
            header("CPU", value: Format.percent(snapshot.cpu.total))

            chart([HistorySeries(name: "CPU", points: history, color: .accentColor, format: Format.percent)],
                  ceiling: 1, summary: history.summary(Format.percent))

            CoreBars(loads: snapshot.cpu.perCore, layout: engine.coreLayout)

            HStack(spacing: 14) {
                legend("User", Format.percent(snapshot.cpu.user))
                legend("System", Format.percent(snapshot.cpu.system))
                legend("Idle", Format.percent(snapshot.cpu.idle))
            }
        }
    }

    private var memory: some View {
        let history = points(snapshot.memoryHistory)
        return VStack(alignment: .leading, spacing: 8) {
            header(
                "Memory",
                value: "\(Format.bytes(snapshot.memory.used)) / \(Format.bytes(snapshot.memory.total))"
            )

            chart([HistorySeries(name: "RAM", points: history, color: .purple, format: Format.percent)],
                  ceiling: 1, summary: history.summary(Format.percent))
                .help("Memory used as a fraction of physical RAM; this graph does not measure memory pressure.")

            // Components sum to Used; pressure and swap provide context.
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    legend("App", Format.bytes(snapshot.memory.app))
                    legend("Wired", Format.bytes(snapshot.memory.wired))
                    legend("Compressed", Format.bytes(snapshot.memory.compressed))
                }
                GridRow {
                    legend("Swap", Format.bytes(snapshot.memory.swapUsed))
                    legend("Pressure", snapshot.memory.pressureLabel,
                           tint: pressureColor, warns: snapshot.memory.pressureLevel > 1)
                }
            }
        }
    }

    private var network: some View {
        let down = points(snapshot.downloadHistory), up = points(snapshot.uploadHistory)
        return VStack(alignment: .leading, spacing: 8) {
            header(
                "Network",
                value: snapshot.network.interface.isEmpty
                    ? "—"
                    : "\(snapshot.network.interface)  \(snapshot.network.ipAddress ?? "")"
            )

            chart([
                HistorySeries(name: "↓ Down", points: down, color: .blue, format: Format.rate),
                HistorySeries(name: "↑ Up", points: up, color: .green, format: Format.rate),
            ], ceiling: ceiling([down, up]), summary: "↓ \(down.summary(Format.rate))")
                .help("Physical interfaces only, so VPN traffic is not counted twice. The scale follows the busiest moment in view.")

            HStack(spacing: 14) {
                legend("↓ Down", Format.rate(snapshot.network.download), tint: .blue)
                legend("↑ Up", Format.rate(snapshot.network.upload), tint: .green)
            }

            Text("↓ \(Format.bytes(snapshot.network.sessionReceived)) ↑ \(Format.bytes(snapshot.network.sessionSent)) since launch")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var disk: some View {
        let read = points(snapshot.diskReadHistory), write = points(snapshot.diskWriteHistory)
        let isLow = snapshot.disk.total > 0 && snapshot.disk.freeFraction < engine.thresholds.diskFree
        return VStack(alignment: .leading, spacing: 8) {
            header(
                "Disk",
                value: "\(Format.bytes(snapshot.disk.free)) free of \(Format.bytes(snapshot.disk.total))",
                warns: isLow
            )

            // Capacity bar. Unlike activity, capacity is a level rather than a
            // rate, so a chart of it would be a flat line all day.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule()
                        .fill(isLow ? Color.orange : Color.accentColor)
                        .frame(width: geometry.size.width * snapshot.disk.usedFraction)
                }
            }
            .frame(height: 6)
            .accessibilityElement()
            .accessibilityLabel("Disk used")
            .accessibilityValue(Format.percent(snapshot.disk.usedFraction))

            chart([
                HistorySeries(name: "Read", points: read, color: .blue, format: Format.rate),
                HistorySeries(name: "Write", points: write, color: .pink, format: Format.rate),
            ], ceiling: ceiling([read, write]), summary: "Write \(write.summary(Format.rate))")
                .help("All internal and external disks. The scale follows the busiest moment in view.")

            HStack(spacing: 14) {
                legend("Read", Format.rate(snapshot.disk.read), tint: .blue)
                legend("Write", Format.rate(snapshot.disk.write), tint: .pink)
                legend("Used", Format.percent(snapshot.disk.usedFraction))
            }
        }
    }

    private var temperature: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(
                "Temperature",
                value: snapshot.thermal.cpu.map(Format.celsius) ?? "—"
            )

            HStack(spacing: 14) {
                if let average = snapshot.thermal.cpuAverage {
                    legend("Die avg", Format.celsius(average))
                }
                if let gpu = snapshot.thermal.gpu {
                    legend("GPU", Format.celsius(gpu))
                }
                if let ssd = snapshot.thermal.ssd {
                    legend("SSD", Format.celsius(ssd))
                }
                if let battery = snapshot.thermal.battery {
                    legend("Battery", Format.celsius(battery))
                }
                if snapshot.thermal.state != .nominal {
                    legend("State", thermalStateLabel, tint: .orange, warns: true)
                }
            }
        }
    }

    private func battery(_ battery: BatterySample) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header("Battery", value: "\(battery.percent)%", warns: battery.isLow)

            HStack(spacing: 14) {
                legend("State", batteryState(battery))
                if let minutes = battery.minutesRemaining {
                    legend(battery.state == .charging ? "Until full" : "Remaining", Format.duration(Double(minutes) * 60))
                }
                if let watts = battery.watts {
                    legend("System", String(format: "%.1f W", watts))
                }
                if let cycles = battery.cycleCount {
                    legend("Cycles", "\(cycles)")
                }
            }
        }
    }

    private func batteryState(_ battery: BatterySample) -> String {
        switch battery.state {
        case .discharging: "On battery"
        case .charging: "Charging"
        case .charged: "Charged"
        case .pluggedIn: "Plugged in"
        }
    }

    /// Time when there is an estimate, otherwise whatever is true of the state.
    private func batteryCaption(_ battery: BatterySample) -> String {
        guard let minutes = battery.minutesRemaining else { return batteryState(battery) }
        let time = Format.duration(Double(minutes) * 60)
        return battery.state == .charging ? "\(time) to full" : "\(time) left"
    }

    // MARK: - Building blocks

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var divider: some View {
        Divider().opacity(0.5)
    }

    private func header(_ title: String, value: String, warns: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold))
            if warns {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Warning")
            }
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func legend(_ title: String, _ value: String, tint: Color = .primary, warns: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                if warns {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .accessibilityLabel("Warning")
                }
                Text(value)
            }
            .foregroundStyle(tint)
        }
    }

    private var pressureColor: Color {
        switch snapshot.memory.pressureLevel {
        case 4...: .red
        case 2...: .orange
        default: .primary
        }
    }

    private var thermalStateLabel: String {
        switch snapshot.thermal.state {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}

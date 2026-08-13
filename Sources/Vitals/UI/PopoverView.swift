import SwiftUI

/// The detail panel shown when the status item is clicked.
struct PopoverView: View {
    @ObservedObject var engine: MetricsEngine

    private var snapshot: Snapshot { engine.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            section {
                cpu
            }
            divider
            section {
                memory
            }
            divider
            section {
                network
            }
            divider
            section {
                disk
            }
            if snapshot.thermal.cpu != nil {
                divider
                section {
                    temperature
                }
            }
            divider
            section {
                processes
            }
            divider
            footer
        }
        .frame(width: 320)
        .font(.system(size: 11).monospacedDigit())
    }

    // MARK: - Sections

    private var cpu: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("CPU", value: Format.percent(snapshot.cpu.total))

            Sparkline(values: snapshot.cpuHistory.values, ceiling: 1, color: .accentColor)
                .frame(height: 32)

            CoreBars(
                loads: snapshot.cpu.perCore,
                performanceCoreCount: engine.performanceCoreCount
            )

            HStack(spacing: 14) {
                legend("User", Format.percent(snapshot.cpu.user))
                legend("System", Format.percent(snapshot.cpu.system))
                legend("Idle", Format.percent(snapshot.cpu.idle))
            }
        }
    }

    private var memory: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(
                "Memory",
                value: "\(Format.bytes(snapshot.memory.used)) / \(Format.bytes(snapshot.memory.total))"
            )

            Sparkline(values: snapshot.memoryHistory.values, ceiling: 1, color: pressureColor)
                .frame(height: 32)

            HStack(spacing: 14) {
                legend("App", Format.bytes(snapshot.memory.app))
                legend("Wired", Format.bytes(snapshot.memory.wired))
                legend("Compressed", Format.bytes(snapshot.memory.compressed))
                legend("Pressure", Format.percent(snapshot.memory.pressure), tint: pressureColor)
            }
        }
    }

    private var network: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(
                "Network",
                value: snapshot.network.interface.isEmpty
                    ? "—"
                    : "\(snapshot.network.interface)  \(snapshot.network.ipAddress ?? "")"
            )

            ZStack {
                Sparkline(values: snapshot.downloadHistory.values, ceiling: nil, color: .blue)
                Sparkline(
                    values: snapshot.uploadHistory.values, ceiling: nil,
                    color: .green, filled: false
                )
            }
            .frame(height: 32)

            HStack(spacing: 14) {
                legend("↓ Down", Format.rate(snapshot.network.download), tint: .blue)
                legend("↑ Up", Format.rate(snapshot.network.upload), tint: .green)
                legend("Session", "\(Format.bytes(snapshot.network.sessionReceived)) in")
            }
        }
    }

    private var disk: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(
                "Disk",
                value: "\(Format.bytes(snapshot.disk.free)) free of \(Format.bytes(snapshot.disk.total))"
            )

            // Capacity bar. Unlike the other metrics this one is a level, not
            // a rate, so a sparkline of it would be a flat line all day.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule()
                        .fill(snapshot.disk.freeFraction < 0.1 ? Color.orange : Color.accentColor)
                        .frame(width: geometry.size.width * snapshot.disk.usedFraction)
                }
            }
            .frame(height: 6)

            HStack(spacing: 14) {
                legend("Read", Format.rate(snapshot.disk.read))
                legend("Write", Format.rate(snapshot.disk.write))
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
                    legend("State", thermalStateLabel, tint: .orange)
                }
            }
        }
    }

    private var processes: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("Top processes", value: "")

            if snapshot.processes.topByCPU.isEmpty {
                Text("Sampling…").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(snapshot.processes.topByCPU) { row in
                        processRow(row, detail: Format.percent(row.cpu))
                    }
                }

                Text("By memory")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    ForEach(snapshot.processes.topByMemory) { row in
                        processRow(row, detail: Format.bytes(row.memory))
                    }
                }
            }
        }
    }

    private func processRow(_ row: ProcessInfoRow, detail: String) -> some View {
        HStack(spacing: 8) {
            Text(row.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(detail)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Text(rateLabel)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Building blocks

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }

    private var divider: some View {
        Divider().opacity(0.5)
    }

    private func header(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .semibold))
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func legend(_ title: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).foregroundStyle(tint)
        }
    }

    /// Shows the sampling rate, and says so when Low Power Mode is the reason
    /// it is slower than configured — otherwise the halved rate looks like a
    /// bug rather than the intended behaviour.
    private var rateLabel: String {
        let interval = engine.effectiveInterval
        let rate = String(format: interval < 1 ? "%.1fs" : "%.0fs", interval)
        return ProcessInfo.processInfo.isLowPowerModeEnabled
            ? "Vitals · \(rate) · low power"
            : "Vitals · \(rate)"
    }

    private var pressureColor: Color {
        switch snapshot.memory.pressureLevel {
        case 4...: .red
        case 2...: .orange
        default: .purple
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

import SwiftUI

/// The few settings there are, as a pane of the panel.
///
/// A pane rather than a window or a nested popover: a transient popover closes
/// the moment focus leaves it, which would take a settings window's owner away
/// with it. Changes apply as they are made, because the config file reloads
/// live and there is nothing to confirm.
struct SettingsView: View {
    @ObservedObject var store: ConfigStore
    var editConfig: () -> Void
    var close: () -> Void

    @State private var startsAtLogin = LoginItem.isEnabled

    private static let intervals: [Double] = [1, 2, 5, 10]

    /// Enabled metrics in their priority order, then everything else.
    private var metrics: [Metric] {
        store.config.menuBar + Metric.allCases.filter { !store.config.menuBar.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button(action: close) {
                    Label("Back", systemImage: "chevron.left").labelStyle(.iconOnly).font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Back")
                Text("Settings").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            if !store.canSave {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("config.json has an error, so changes can't be saved.")
                    Spacer(minLength: 0)
                    Button("Open", action: editConfig).controlSize(.small)
                }
                .padding(8)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }

            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 14) {
                menuBarSection
                Divider().opacity(0.5)
                samplingSection
                Divider().opacity(0.5)
                warningsSection
                Divider().opacity(0.5)
                Toggle("Start at Login", isOn: Binding(
                    get: { startsAtLogin },
                    set: { LoginItem.setEnabled($0); startsAtLogin = LoginItem.isEnabled }
                ))
                .toggleStyle(.checkbox)
            }
            .padding(14)
            .disabled(!store.canSave)
        }
    }

    private func heading(_ title: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 11, weight: .semibold))
            if let detail { Text(detail).font(.system(size: 10)).foregroundStyle(.secondary) }
        }
    }

    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            heading("Menu bar", detail: "Top of the list stays longest when space runs out")
            ForEach(metrics, id: \.self) { metric in
                metricRow(metric)
            }
        }
    }

    private func metricRow(_ metric: Metric) -> some View {
        let enabled = store.config.menuBar.contains(metric)
        let index = store.config.menuBar.firstIndex(of: metric)
        return HStack(spacing: 8) {
            Toggle(metric.settingsName, isOn: Binding(
                get: { enabled },
                set: { _ in store.save(store.config.togglingMetric(metric)) }
            ))
            .toggleStyle(.checkbox)
            .disabled(enabled && store.config.menuBar.count == 1)
            Spacer()
            if enabled {
                moveButton(metric, by: -1, symbol: "chevron.up", label: "Move \(metric.settingsName) up",
                           disabled: index == 0)
                moveButton(metric, by: 1, symbol: "chevron.down", label: "Move \(metric.settingsName) down",
                           disabled: index == store.config.menuBar.count - 1)
            }
        }
    }

    private func moveButton(_ metric: Metric, by offset: Int, symbol: String, label: String, disabled: Bool) -> some View {
        Button { store.save(store.config.movingMetric(metric, by: offset)) } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : Color.secondary)
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private var samplingSection: some View {
        let current = store.config.sampleInterval
        // A value set by hand is shown rather than silently misrepresented.
        let choices = Self.intervals.contains(current) ? Self.intervals : (Self.intervals + [current]).sorted()
        return HStack {
            heading("Sample every")
            Spacer()
            Picker("Sample every", selection: Binding(
                get: { current },
                set: { value in
                    var config = store.config
                    config.sampleInterval = value
                    store.save(config)
                }
            )) {
                ForEach(choices, id: \.self) { Text(String(format: "%g s", $0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }

    private var warningsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            heading("Warn when")
            threshold("CPU at or above", value: store.config.thresholds.cpu, in: 0.1...1, step: 0.05,
                      format: Format.percent) { $0.cpu = $1 }
            threshold("Disk free below", value: store.config.thresholds.diskFree, in: 0.05...0.5, step: 0.05,
                      format: Format.percent) { $0.diskFree = $1 }
            threshold("Temperature at or above", value: store.config.thresholds.temperature, in: 60...110, step: 5,
                      format: Format.celsius) { $0.temperature = $1 }
        }
    }

    private func threshold(_ title: String, value: Double, in range: ClosedRange<Double>, step: Double,
                           format: @escaping (Double) -> String,
                           set: @escaping (inout Config.Thresholds, Double) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(format(value)).foregroundStyle(.secondary)
            Stepper(title, value: Binding(
                get: { value },
                set: { new in
                    var config = store.config
                    set(&config.thresholds, new)
                    store.save(config)
                }
            ), in: range, step: step)
            .labelsHidden()
            .controlSize(.small)
        }
    }
}

private extension Metric {
    var settingsName: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .network: "Network"
        case .disk: "Disk free"
        case .temperature: "Temperature"
        case .battery: "Battery"
        }
    }
}

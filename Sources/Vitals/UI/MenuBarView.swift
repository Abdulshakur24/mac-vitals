import SwiftUI

/// The layout currently on display, as an observable so the readout can change
/// shape without the status item's hosting view being rebuilt underneath it.
final class MenuBarLayoutModel: ObservableObject {
    @Published var layout = MenuBarLayout(items: [])
}

/// The compact readout that lives in the menu bar.
///
/// Every metric occupies a fixed width and every digit is monospaced. Both are
/// deliberate: a status item sizes itself to its content, so a readout that
/// grows a few points when CPU crosses 9% to 10% drags everything to its left
/// sideways on every tick. Fixed widths also let the app compute the status
/// item length up front instead of measuring after each layout pass.
///
/// Which metrics appear, and how fully, is `MenuBarLayout`'s decision — see
/// there for what happens when the bar runs out of room.
struct MenuBarView: View {
    @ObservedObject var engine: MetricsEngine
    @ObservedObject var layoutModel: MenuBarLayoutModel

    private static let horizontalPadding: CGFloat = 5

    var body: some View {
        let layout = layoutModel.layout
        HStack(spacing: layout.spacing) {
            ForEach(layout.items, id: \.metric) { item in
                block(for: item.metric, style: item.style)
                    .frame(width: item.metric.width(item.style), alignment: .leading)
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .font(.system(size: 11).monospacedDigit())
        .frame(height: 22)
    }

    @ViewBuilder
    private func block(for metric: Metric, style: Metric.Style) -> some View {
        switch metric {
        case .cpu:
            HStack(spacing: 4) {
                // The sparkline is the first thing to go: it is context for a
                // number that is right beside it, so losing it costs history
                // rather than the reading itself.
                if style == .full {
                    HistoryChart(points: engine.snapshot.cpuHistory.points(endingAt: engine.snapshot.sampledAt, duration: 60),
                                 end: engine.snapshot.sampledAt, duration: 60, ceiling: 1, color: .secondary)
                        .frame(width: 22, height: 13)
                }
                Text(Format.percent(engine.snapshot.cpu.total))
                    .foregroundStyle(engine.snapshot.cpu.total >= engine.thresholds.cpu ? .orange : .primary)
            }

        case .memory:
            Text(
                style == .full
                    ? Format.gigabytes(engine.snapshot.memory.used)
                    : Format.wholeGigabytes(engine.snapshot.memory.used)
            )
            .foregroundStyle(engine.snapshot.memory.pressureLevel > 1 ? .orange : .primary)

        case .network:
            // Two stacked rows rather than one wide one: throughput needs both
            // directions, and the menu bar has far more vertical room to spare
            // than horizontal. Compacting drops the unit suffix and the
            // decimal, not a direction — one number alone cannot say whether
            // the machine is sending or receiving.
            VStack(alignment: .leading, spacing: -1) {
                rateRow("↓", rate(engine.snapshot.network.download, style))
                rateRow("↑", rate(engine.snapshot.network.upload, style))
            }

        case .disk:
            Text(Format.percent(engine.snapshot.disk.freeFraction))
                .foregroundStyle(engine.snapshot.disk.freeFraction < engine.thresholds.diskFree ? .orange : .primary)

        case .temperature:
            if let temperature = engine.snapshot.thermal.cpu {
                Text(Format.celsius(temperature))
                    .foregroundStyle(temperature >= engine.thresholds.temperature ? .orange : .primary)
            } else {
                // Sensors unavailable: show nothing rather than a fake zero.
                Text("")
            }
        }
    }

    private func rate(_ value: Double, _ style: Metric.Style) -> String {
        style == .full ? Format.rate(value) : Format.compactRate(value)
    }

    private func rateRow(_ arrow: String, _ value: String) -> some View {
        HStack(spacing: 2) {
            Text(arrow)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 9).monospacedDigit())
            Spacer(minLength: 0)
        }
    }
}

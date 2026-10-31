import SwiftUI

/// The sections of the History tab, which are also what a module opens.
enum HistorySection: String, Hashable {
    case cpu, memory, network, disk, temperature, battery
}

/// One metric as a pill: a white disc holding its icon, then the reading.
struct GlanceTile: Identifiable {
    var id: HistorySection
    var title: String
    var value: String
    var symbol: String
    /// Replaces the title for a metric with two readings of equal weight.
    var titleOverride: String?
    /// A second fact, set small at the end of the pill.
    var caption: String?
    var isAlert = false
    /// Recent history, at the end of the pill, for metrics worth seeing as a line.
    var sparkline: [HistoryPoint] = []
    var sparklineCeiling: Double = 1
    /// What VoiceOver reads for the value, when the short form relies on being
    /// seen. Falls back to the value and caption.
    var spokenValue: String?

    var spoken: String {
        let value = spokenValue ?? [value, caption].compactMap { $0 }.joined(separator: ", ")
        return "\(title), \(value)\(isAlert ? ", warning" : "")"
    }
}

/// A level out of a known whole, drawn like Control Center's Display slider.
struct GlanceBar: Identifiable {
    var id: HistorySection
    var title: String
    var value: String
    var fraction: Double
    var symbol: String
    var isAlert = false
}

/// The whole machine at a glance, without scrolling. Each module opens the
/// History tab at that metric.
struct GlanceModules: View {
    var tiles: [GlanceTile]
    var bars: [GlanceBar]
    var end: TimeInterval
    var duration: TimeInterval
    var select: (HistorySection) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)

    var body: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(tiles) { tile in
                    Button { select(tile.id) } label: { pill(tile) }
                        .buttonStyle(.plain)
                        .help("Show \(tile.title) history")
                        .accessibilityLabel(tile.spoken)
                        .accessibilityHint("Shows \(tile.title) history")
                }
            }
            ForEach(bars) { bar in
                Button { select(bar.id) } label: { wide(bar) }
                    .buttonStyle(.plain)
                    .help("Show \(bar.title) history")
                    .accessibilityLabel("\(bar.title), \(bar.value)\(bar.isAlert ? ", warning" : "")")
                    .accessibilityHint("Shows \(bar.title) history")
            }
        }
    }

    private func pill(_ tile: GlanceTile) -> some View {
        HStack(spacing: 10) {
            disc(tile.symbol, isAlert: tile.isAlert)
            VStack(alignment: .leading, spacing: 0) {
                Text(tile.titleOverride ?? tile.title)
                    .font(.system(size: tile.titleOverride == nil ? 11 : 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tile.titleOverride == nil ? Color.secondary : Color.primary)
                Text(tile.value)
                    .font(.system(size: tile.titleOverride == nil ? 14 : 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tile.isAlert ? Color.orange : Color.primary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
            trailing(tile)
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .frame(height: 56)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Capsule())
        .glassModule(in: Capsule(), interactive: true)
    }

    @ViewBuilder
    private func trailing(_ tile: GlanceTile) -> some View {
        if !tile.sparkline.isEmpty {
            HistorySparkline(points: tile.sparkline, end: end, duration: duration,
                             ceiling: tile.sparklineCeiling, color: .white.opacity(0.75))
                .frame(width: 42, height: 22)
                .accessibilityHidden(true)
        } else if let caption = tile.caption {
            Text(caption)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: 56, alignment: .trailing)
        }
    }

    /// Orange and a warning sign together: a colour alone says nothing to
    /// anyone who can't tell it from the blue.
    private func disc(_ symbol: String, isAlert: Bool) -> some View {
        ZStack {
            Circle().fill(.white)
            Image(systemName: isAlert ? "exclamationmark.triangle.fill" : symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isAlert ? Color.orange : Color.blue)
        }
        .frame(width: 40, height: 40)
        // Glass applies vibrancy to what sits on it, which bleaches a coloured
        // icon on a white disc. Flattened, the disc arrives as one opaque image.
        .drawingGroup()
        .accessibilityHidden(true)
    }

    private func wide(_ bar: GlanceBar) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(bar.title).font(.system(size: 12, weight: .semibold))
                if bar.isAlert {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(bar.value)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 10) {
                Image(systemName: bar.symbol)
                    .font(.system(size: 12))
                    .frame(width: 16)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule()
                            .fill(bar.isAlert ? Color.orange : Color.white)
                            .frame(width: max(6, geometry.size.width * min(1, max(0, bar.fraction))))
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 24))
        .glassModule(in: RoundedRectangle(cornerRadius: 24), interactive: true)
    }
}

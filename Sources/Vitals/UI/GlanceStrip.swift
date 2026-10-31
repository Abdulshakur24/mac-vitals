import SwiftUI

/// The sections of the History tab, which are also what a tile opens.
enum HistorySection: String, Hashable {
    case cpu, memory, network, disk, temperature, battery
}

/// One metric in the strip at the top of the panel.
struct GlanceTile: Identifiable {
    var id: HistorySection
    var title: String
    var value: String
    /// A second fact, where one number does not say enough.
    var caption: String?
    var isAlert = false
    /// Recent history, for metrics with one worth seeing at this size.
    var sparkline: [HistoryPoint] = []
    var sparklineCeiling: Double = 1
    var tint: Color = .secondary
    /// What VoiceOver reads for the value, when the short form relies on being
    /// seen. Falls back to the value and caption.
    var spokenValue: String?
}

/// The whole machine at a glance, without scrolling. Each tile opens the
/// History tab at that metric.
struct GlanceStrip: View {
    var tiles: [GlanceTile]
    var end: TimeInterval
    var duration: TimeInterval
    var select: (HistorySection) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(tiles) { tile in
                Button { select(tile.id) } label: { label(tile) }
                    .buttonStyle(.plain)
                    .help("Show \(tile.title) history")
                    .accessibilityLabel("\(tile.title), \(tile.spokenValue ?? [tile.value, tile.caption].compactMap { $0 }.joined(separator: ", "))\(tile.isAlert ? ", warning" : "")")
                    .accessibilityHint("Shows \(tile.title) history")
            }
        }
    }

    private func label(_ tile: GlanceTile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(tile.title).font(.system(size: 10)).foregroundStyle(.secondary)
                if tile.isAlert {
                    // Orange alone would not say anything to everyone.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
            }
            Text(tile.value)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(tile.isAlert ? Color.orange : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            detail(tile).frame(height: 14, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func detail(_ tile: GlanceTile) -> some View {
        if !tile.sparkline.isEmpty {
            HistorySparkline(points: tile.sparkline, end: end, duration: duration,
                             ceiling: tile.sparklineCeiling, color: tile.tint)
        } else if let caption = tile.caption {
            Text(caption)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

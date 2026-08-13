import SwiftUI

/// Per-core load as a row of vertical bars, split into performance and
/// efficiency groups.
///
/// The split matters on Apple Silicon: four saturated E-cores and four
/// saturated P-cores are very different situations, and a single aggregate
/// percentage hides which one you are in.
struct CoreBars: View {
    var loads: [Double]
    var performanceCoreCount: Int

    private var performanceLoads: [Double] {
        Array(loads.prefix(performanceCoreCount))
    }
    private var efficiencyLoads: [Double] {
        performanceCoreCount < loads.count
            ? Array(loads.dropFirst(performanceCoreCount)) : []
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if !performanceLoads.isEmpty {
                group(performanceLoads, label: "P", tint: .accentColor)
            }
            if !efficiencyLoads.isEmpty {
                group(efficiencyLoads, label: "E", tint: .teal)
            }
            Spacer(minLength: 0)
        }
    }

    private func group(_ values: [Double], label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, load in
                    bar(load: load, tint: tint)
                }
            }
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private func bar(load: Double, tint: Color) -> some View {
        let clamped = min(max(load, 0), 1)
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.primary.opacity(0.1))
            RoundedRectangle(cornerRadius: 1.5)
                .fill(clamped >= 0.9 ? Color.orange : tint)
                // A fully idle core still shows a sliver, so the bar reads as
                // "present and idle" rather than "missing".
                .frame(height: max(1.5, 26 * clamped))
        }
        .frame(width: 7, height: 26)
    }
}

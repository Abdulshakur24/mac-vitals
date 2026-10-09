import SwiftUI

struct HistorySparkline: View {
    var points: [HistoryPoint]
    var end: TimeInterval
    var duration: TimeInterval
    var ceiling: Double
    var color: Color

    var body: some View {
        Canvas { context, size in
            guard ceiling > 0 else { return }
            var path = Path()
            for (index, sample) in points.enumerated() {
                let point = CGPoint(
                    x: size.width * min(1, max(0, (sample.time - end + duration) / duration)),
                    y: size.height * (1 - min(1, max(0, sample.value / ceiling)))
                )
                if index == 0 || sample.startsSegment {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
                // A line needs two points to show at all, so a sample alone in
                // its segment — right after wake, say — gets a dot instead.
                // Everywhere else the line is enough; a dot on every point of an
                // hour of history would thicken it into a band.
                let opensSegment = index == 0 || sample.startsSegment
                let continues = index + 1 < points.count && !points[index + 1].startsSegment
                if opensSegment, !continues {
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)), with: .color(color))
                }
            }
            context.stroke(path, with: .color(color), lineWidth: 1)
        }
        .accessibilityLabel("History chart")
        .accessibilityValue(points.isEmpty ? "No samples yet" : "\(points.count) peak samples")
    }
}

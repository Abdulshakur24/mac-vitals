import SwiftUI

/// A filled line chart over a fixed history window.
///
/// Drawn with `Canvas` rather than `Path` in a `Shape` so the whole series is
/// one draw call, and with no implicit animation anywhere — an animated
/// sparkline would keep the display awake redrawing between samples, which is
/// exactly the cost this app is trying to avoid.
struct Sparkline: View {
    var values: [Double]
    /// Upper bound of the value range. Pass nil to autoscale to the series max.
    var ceiling: Double?
    var color: Color = .secondary
    var filled = true

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            guard values.count > 1 else { return }

            let top = ceiling ?? max(values.max() ?? 1, .leastNonzeroMagnitude)
            guard top > 0 else { return }

            let stepX = size.width / CGFloat(values.count - 1)
            func point(_ index: Int) -> CGPoint {
                let normalized = min(max(values[index] / top, 0), 1)
                return CGPoint(
                    x: CGFloat(index) * stepX,
                    y: size.height - CGFloat(normalized) * size.height
                )
            }

            var line = Path()
            line.move(to: point(0))
            for index in 1..<values.count {
                line.addLine(to: point(index))
            }

            if filled {
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(color.opacity(0.28)))
            }

            context.stroke(line, with: .color(color), lineWidth: 1)
        }
        .drawingGroup(opaque: false)
        .animation(nil, value: values)
    }
}

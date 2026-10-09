import SwiftUI

struct HistorySeries {
    var name: String
    var points: [HistoryPoint]
    var color: Color
    var format: (Double) -> String
}

/// Own the readings so an open peak bucket cannot change a pinned value.
struct HistoryInspection: Equatable {
    var time: TimeInterval
    var samples: [HistoryPoint?]

    init(time: TimeInterval, points: [[HistoryPoint]]) {
        self.time = time
        samples = points.map { Self.sample(in: $0, at: time) }
    }

    static func time(at fraction: Double, end: TimeInterval, duration: TimeInterval) -> TimeInterval {
        end - duration + min(1, max(0, fraction)) * duration
    }

    static func sample(in points: [HistoryPoint], at time: TimeInterval) -> HistoryPoint? {
        guard let first = points.first, let last = points.last else { return nil }
        // A bucket spans five seconds, but no reading extends across a gap.
        if time <= first.time { return first.time - time <= 5 ? first : nil }
        if time >= last.time { return time - last.time <= 5 ? last : nil }
        guard let next = points.firstIndex(where: { $0.time >= time }) else { return nil }
        if points[next].time == time { return points[next] }
        guard !points[next].startsSegment else { return nil }
        let previous = points[next - 1]
        return time - previous.time <= points[next].time - time ? previous : points[next]
    }
}

struct HistoryChart: View {
    var series: [HistorySeries]
    var end: TimeInterval
    var duration: TimeInterval
    var ceiling: Double

    @State private var hoverFraction: Double?
    @State private var pinned: HistoryInspection?
    @State private var allowsKeyboardFocus = false
    @FocusState private var focused: Bool

    private var inspection: HistoryInspection? {
        pinned ?? hoverFraction.map {
            HistoryInspection(time: HistoryInspection.time(at: $0, end: end, duration: duration),
                              points: series.map(\.points))
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geometry in
                Canvas { context, size in
                    guard ceiling > 0, duration > 0 else { return }
                    for item in series { draw(item, in: &context, size: size) }
                    if let inspection {
                        let x = position(time: inspection.time, value: 0, size: size).x
                        var cursor = Path()
                        cursor.move(to: CGPoint(x: x, y: 0))
                        cursor.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(cursor, with: .color(.primary.opacity(0.4)),
                                       style: StrokeStyle(lineWidth: 1, dash: pinned == nil ? [2, 2] : []))
                        for (index, sample) in inspection.samples.enumerated() {
                            guard let sample, series.indices.contains(index) else { continue }
                            let point = position(time: sample.time, value: sample.value, size: size)
                            let dot = Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
                            context.fill(dot, with: .color(series[index].color))
                            context.stroke(dot, with: .color(.primary.opacity(0.7)), lineWidth: 1)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): hoverFraction = fraction(location.x, width: geometry.size.width)
                    case .ended: hoverFraction = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { value in pin(at: fraction(value.location.x, width: geometry.size.width)) }
                        .onEnded { value in pin(at: fraction(value.location.x, width: geometry.size.width)) }
                        .exclusively(before: SpatialTapGesture().onEnded { value in
                            allowsKeyboardFocus = true
                            focused = true
                            if pinned != nil { pinned = nil }
                            else { pin(at: fraction(value.location.x, width: geometry.size.width)) }
                        })
                )
            }
            .frame(height: 40)
            .focusable(allowsKeyboardFocus)
            .focused($focused)
            .onChange(of: allowsKeyboardFocus) { _, enabled in
                if enabled { focused = true }
            }
            .onKeyPress(.leftArrow) { moveSelection(forward: false); return .handled }
            .onKeyPress(.rightArrow) { moveSelection(forward: true); return .handled }
            .onKeyPress(.escape) {
                guard pinned != nil else { return .ignored }
                pinned = nil
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(series.map(\.name).joined(separator: " and ")) history")
            .accessibilityValue(accessibilityReading)
            .accessibilityHint("Use arrow keys to inspect samples. Click to pin or release a reading.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: moveSelection(forward: true)
                case .decrement: moveSelection(forward: false)
                @unknown default: break
                }
            }

            readout.frame(height: 16)
        }
        .onChange(of: duration) { _, _ in pinned = nil; hoverFraction = nil }
        .onChange(of: end) { _, value in
            if let pinned, pinned.time < value - duration || pinned.time > value { self.pinned = nil }
        }
    }

    @ViewBuilder private var readout: some View {
        HStack(spacing: 6) {
            if let inspection {
                Text(timestamp(inspection.time)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                ForEach(series.indices, id: \.self) { index in
                    let sample = inspection.samples[index]
                    Text("\(series[index].name) \(sample.map { series[index].format($0.value) } ?? "No sample")")
                        .foregroundStyle(series[index].color)
                }
                if pinned != nil {
                    Button { pinned = nil; hoverFraction = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Release pinned reading")
                    .help("Release pinned reading (Esc)")
                }
            } else {
                Text(duration == 300 ? "−5 min" : "−1 hour")
                Spacer(minLength: 0)
                Text(series.allSatisfy { $0.points.isEmpty } ? "No samples yet" : "Hover to inspect · click to pin")
                Spacer(minLength: 0)
                Text("Now")
            }
        }
        .font(.system(size: 9).monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var accessibilityReading: String {
        guard let inspection else {
            return series.allSatisfy { $0.points.isEmpty } ? "No samples yet" : "\(Int(duration / 60)) minutes of five-second peaks"
        }
        return ([timestamp(inspection.time)] + series.indices.map { index in
            "\(series[index].name) \(inspection.samples[index].map { series[index].format($0.value) } ?? "No sample")"
        }).joined(separator: ", ")
    }

    private func pin(at fraction: Double) {
        allowsKeyboardFocus = true
        focused = true
        pinned = HistoryInspection(time: HistoryInspection.time(at: fraction, end: end, duration: duration),
                                   points: series.map(\.points))
    }

    private func moveSelection(forward: Bool) {
        let times = Set(series.flatMap { $0.points.map(\.time) }).sorted()
        guard let first = times.first, let last = times.last else { return }
        let time: TimeInterval
        if let current = inspection?.time {
            time = forward ? (times.first { $0 > current } ?? last) : (times.last { $0 < current } ?? first)
        } else { time = forward ? first : last }
        pinned = HistoryInspection(time: time, points: series.map(\.points))
    }

    private func fraction(_ x: CGFloat, width: CGFloat) -> Double {
        width > 0 ? min(1, max(0, Double(x / width))) : 0
    }

    private func timestamp(_ time: TimeInterval) -> String {
        Date(timeIntervalSince1970: time).formatted(.dateTime.hour().minute().second())
    }

    private func position(time: TimeInterval, value: Double, size: CGSize) -> CGPoint {
        CGPoint(x: size.width * min(1, max(0, (time - end + duration) / duration)),
                y: 3 + max(0, size.height - 6) * (1 - min(1, max(0, value / ceiling))))
    }

    private func draw(_ item: HistorySeries, in context: inout GraphicsContext, size: CGSize) {
        var path = Path()
        for (index, sample) in item.points.enumerated() {
            let point = position(time: sample.time, value: sample.value, size: size)
            if index == 0 || sample.startsSegment { path.move(to: point) }
            else { path.addLine(to: point) }
            let opensSegment = index == 0 || sample.startsSegment
            let continues = index + 1 < item.points.count && !item.points[index + 1].startsSegment
            if opensSegment, !continues {
                context.fill(Path(ellipseIn: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)), with: .color(item.color))
            }
        }
        context.stroke(path, with: .color(item.color), lineWidth: 1)
    }
}

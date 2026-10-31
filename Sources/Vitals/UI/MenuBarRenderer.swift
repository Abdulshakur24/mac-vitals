import AppKit

/// Everything the menu bar readout draws, and nothing else.
///
/// This is the update key as well as the drawing input. A status item redraws
/// itself once per display every time it changes, and profiling put that at
/// about 95% of what this app does with the panel closed, so two equal readouts
/// must mean the status item is left alone. That is why this holds formatted
/// strings and rounded geometry rather than the raw readings: a reading can
/// move without changing a single pixel.
struct MenuBarReadout: Equatable {
    struct Block: Equatable {
        var metric: Metric
        var style: Metric.Style
        /// One line for most metrics; network stacks two.
        var rows: [Row]
        var isAlert = false
        /// Sparkline polylines in block coordinates. A gap in the history
        /// starts a new one, and one with a single point is drawn as a dot.
        var sparkline: [[CGPoint]] = []
    }

    struct Row: Equatable {
        var prefix: String?
        var value: String
    }

    var blocks: [Block]
    var spacing: CGFloat
    var width: CGFloat

    static let height: CGFloat = 22
    static let horizontalPadding: CGFloat = 5
    static let sparklineSize = CGSize(width: 22, height: 13)
    static let sparklineDuration: TimeInterval = 60
    static let sparklineBucket: TimeInterval = 5

    init(layout: MenuBarLayout, snapshot: Snapshot, thresholds: Config.Thresholds) {
        spacing = layout.spacing
        width = layout.width
        blocks = layout.items.map { Self.block(for: $0, snapshot: snapshot, thresholds: thresholds) }
    }

    /// Whether this must replace `other` at once rather than wait its turn.
    /// An alert appearing or clearing is the reason to look at the menu bar,
    /// and a new width has already resized the item around the old image.
    func isUrgent(comparedTo other: MenuBarReadout) -> Bool {
        width != other.width || blocks.map(\.isAlert) != other.blocks.map(\.isAlert)
    }

    private static func block(for item: MenuBarLayout.Item, snapshot: Snapshot,
                              thresholds: Config.Thresholds) -> Block {
        let style = item.style
        switch item.metric {
        case .cpu:
            // The sparkline is the first thing to go: it is context for a
            // number that is right beside it, so losing it costs history
            // rather than the reading itself.
            return Block(metric: .cpu, style: style,
                         rows: [Row(value: Format.percent(snapshot.cpu.total))],
                         isAlert: snapshot.cpu.total >= thresholds.cpu,
                         sparkline: style == .full ? sparkline(snapshot) : [])

        case .memory:
            let value = style == .full
                ? Format.gigabytes(snapshot.memory.used)
                : Format.wholeGigabytes(snapshot.memory.used)
            return Block(metric: .memory, style: style, rows: [Row(value: value)],
                         isAlert: snapshot.memory.pressureLevel > 1)

        case .network:
            // Two stacked rows rather than one wide one: throughput needs both
            // directions, and the menu bar has far more vertical room to spare
            // than horizontal. Compacting drops the unit suffix and the
            // decimal, not a direction — one number alone cannot say whether
            // the machine is sending or receiving.
            func rate(_ value: Double) -> String {
                style == .full ? Format.rate(value) : Format.compactRate(value)
            }
            return Block(metric: .network, style: style, rows: [
                Row(prefix: "↓", value: rate(snapshot.network.download)),
                Row(prefix: "↑", value: rate(snapshot.network.upload)),
            ])

        case .disk:
            return Block(metric: .disk, style: style,
                         rows: [Row(value: Format.percent(snapshot.disk.freeFraction))],
                         isAlert: snapshot.disk.freeFraction < thresholds.diskFree)

        case .temperature:
            // Sensors unavailable: show nothing rather than a fake zero.
            guard let temperature = snapshot.thermal.cpu else {
                return Block(metric: .temperature, style: style, rows: [])
            }
            return Block(metric: .temperature, style: style,
                         rows: [Row(value: Format.celsius(temperature))],
                         isAlert: temperature >= thresholds.temperature)
        }
    }

    /// The last minute of CPU, snapped to whole buckets and half points.
    ///
    /// The chart in the panel slides continuously. This one must not: a line
    /// that moves a fraction of a point on every sample would change the
    /// readout on every sample, and the point of this type is to be able to
    /// say that nothing changed.
    private static func sparkline(_ snapshot: Snapshot) -> [[CGPoint]] {
        let duration = sparklineDuration, bucket = sparklineBucket, size = sparklineSize
        let end = (snapshot.sampledAt / bucket).rounded(.up) * bucket
        var lines: [[CGPoint]] = []
        for sample in snapshot.cpuHistory.points(endingAt: snapshot.sampledAt, duration: duration) {
            let time = (sample.time / bucket).rounded(.down) * bucket
            let x = size.width * min(1, max(0, (time - end + duration) / duration))
            let y = size.height * (1 - min(1, max(0, sample.value)))
            let point = CGPoint(x: (x * 2).rounded() / 2, y: (y * 2).rounded() / 2)
            if sample.startsSegment || lines.isEmpty { lines.append([point]) }
            else { lines[lines.count - 1].append(point) }
        }
        return lines
    }
}

extension Snapshot {
    /// One sentence covering every metric, for the tooltip and VoiceOver.
    ///
    /// Independent of the layout, so a reading the menu bar has run out of room
    /// for can still be reached. Before the first sample there is nothing to
    /// say, and a row of zeros would be a false reading.
    var summary: String {
        guard sampledAt > 0, !cpu.perCore.isEmpty else { return "Vitals" }
        var parts = [
            "CPU \(Format.percent(cpu.total))",
            "Memory \(Format.bytes(memory.used)) of \(Format.bytes(memory.total))",
            "Download \(Format.rate(network.download))",
            "Upload \(Format.rate(network.upload))",
            "Disk \(Format.bytes(disk.free)) free",
        ]
        if let temperature = thermal.cpu { parts.append("Temperature \(Format.celsius(temperature))") }
        let warnings = attention.filter { $0.endedAt == nil }.map(\.title)
        return (parts + warnings).joined(separator: ", ")
    }
}

/// Draws a readout into an image for the status button.
///
/// Fixed widths and monospaced digits are deliberate. A status item sizes
/// itself to its content, so a readout that grows a few points when CPU crosses
/// 9% to 10% drags everything to its left sideways on every tick. Fixed widths
/// also let the app compute the status item length up front.
///
/// An image rather than a hosted SwiftUI view because the view has to be laid
/// out again for every copy of the menu bar on every change, and that was
/// almost all of the app's idle CPU. Which metrics appear, and how fully, is
/// `MenuBarLayout`'s decision.
enum MenuBarRenderer {
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let rowFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
    private static let arrowFont = NSFont.systemFont(ofSize: 8)

    /// Colours for one way of drawing. Template images carry only coverage, so
    /// there "secondary" is a lighter alpha that the system tints with the rest.
    private struct Palette {
        var primary: NSColor
        var secondary: NSColor
    }

    /// A template bitmap, or a colour drawing while something is in alert.
    ///
    /// A template is the normal case because AppKit draws the item several
    /// times over per change, once for each menu bar copy and appearance. A
    /// bitmap sets the text once, and the system's tint is right for every one
    /// of those copies, including a dimmed inactive display.
    ///
    /// Orange cannot be a template. That image draws when the button does and
    /// is not cached, because `labelColor` is only right if it is resolved
    /// during each menu bar's own draw. It is the rare state, so it can pay.
    static func image(for readout: MenuBarReadout) -> NSImage {
        let size = NSSize(width: readout.width, height: MenuBarReadout.height)
        guard !readout.blocks.contains(where: \.isAlert) else {
            let image = drawing(readout, size: size, palette: Palette(primary: .labelColor, secondary: .secondaryLabelColor))
            image.cacheMode = .never
            return image
        }
        let image = NSImage(size: size)
        if let bitmap = bitmap(of: readout, size: size) { image.addRepresentation(bitmap) }
        image.isTemplate = true
        return image
    }

    private static func drawing(_ readout: MenuBarReadout, size: NSSize, palette: Palette) -> NSImage {
        NSImage(size: size, flipped: true) { _ in
            var x = MenuBarReadout.horizontalPadding
            for block in readout.blocks {
                draw(block, at: x, palette: palette)
                x += block.metric.width(block.style) + readout.spacing
            }
            return true
        }
    }

    /// Always 2x: a menu bar on a 1x display scales it down, and sharp text on
    /// the built-in display is the common case.
    private static func bitmap(of readout: MenuBarReadout, size: NSSize) -> NSBitmapImageRep? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        bitmap.size = size

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        // The context counts pixels whatever `size` says, so points need scaling.
        context.cgContext.scaleBy(x: 2, y: 2)
        drawing(readout, size: size, palette: Palette(primary: .black, secondary: .black.withAlphaComponent(0.6)))
            .draw(in: NSRect(origin: .zero, size: size))
        return bitmap
    }

    private static func draw(_ block: MenuBarReadout.Block, at origin: CGFloat, palette: Palette) {
        let color: NSColor = block.isAlert ? .systemOrange : palette.primary
        var x = origin

        if block.metric == .cpu, block.style == .full {
            let size = MenuBarReadout.sparklineSize
            palette.secondary.set()
            drawSparkline(block.sparkline, in: CGRect(x: x, y: (MenuBarReadout.height - size.height) / 2,
                                                      width: size.width, height: size.height))
            x += size.width + 4
        }

        if block.rows.count == 2 {
            for (index, row) in block.rows.enumerated() {
                let top: CGFloat = index == 0 ? 0 : 10
                var rowX = x
                if let prefix = row.prefix {
                    let arrow = NSAttributedString(string: prefix, attributes: [
                        .font: arrowFont, .foregroundColor: palette.secondary,
                    ])
                    arrow.draw(at: CGPoint(x: rowX, y: top + 1))
                    rowX += arrow.size().width + 2
                }
                NSAttributedString(string: row.value, attributes: [
                    .font: rowFont, .foregroundColor: color,
                ]).draw(at: CGPoint(x: rowX, y: top))
            }
        } else if let row = block.rows.first {
            let text = NSAttributedString(string: row.value, attributes: [
                .font: valueFont, .foregroundColor: color,
            ])
            text.draw(at: CGPoint(x: x, y: (MenuBarReadout.height - text.size().height) / 2))
        }
    }

    private static func drawSparkline(_ lines: [[CGPoint]], in rect: CGRect) {
        for line in lines {
            guard let first = line.first else { continue }
            let start = CGPoint(x: rect.minX + first.x, y: rect.minY + first.y)
            // A line needs two points to show at all, so a sample alone in its
            // segment — right after wake, say — gets a dot instead.
            if line.count == 1 {
                NSBezierPath(ovalIn: CGRect(x: start.x - 1, y: start.y - 1, width: 2, height: 2)).fill()
                continue
            }
            let path = NSBezierPath()
            path.lineWidth = 1
            path.move(to: start)
            for point in line.dropFirst() {
                path.line(to: CGPoint(x: rect.minX + point.x, y: rect.minY + point.y))
            }
            path.stroke()
        }
    }
}

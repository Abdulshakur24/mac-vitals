import CoreGraphics

enum Metric: String, Hashable, CaseIterable, Codable {
    case cpu
    case memory
    case network
    case disk
    case temperature

    /// How much of a metric is drawn.
    ///
    /// `compact` keeps the number and drops everything around it — the CPU
    /// sparkline, the decimal on memory, the units on network rates. The
    /// reading survives; only its ornament goes.
    enum Style: Hashable {
        case full
        case compact
    }

    /// Fixed point width of this metric's block, sized for its widest plausible
    /// value in the given style.
    func width(_ style: Style) -> CGFloat {
        switch (self, style) {
        case (.cpu, .full): 56         // sparkline + "100%"
        case (.cpu, .compact): 30      // "100%"
        case (.memory, .full): 36      // "23.4G"
        case (.memory, .compact): 28   // "128G"
        case (.network, .full): 62     // two stacked rows of "12.4 MB/s"
        case (.network, .compact): 34  // two stacked rows of "12M"
        case (.disk, .full): 34        // "100%"
        case (.disk, .compact): 30     // "100%", tighter
        case (.temperature, _): 26     // "100°" is already minimal
        }
    }
}

/// Which metrics the menu bar draws right now, and how fully.
///
/// A status item that does not fit is not clipped or shrunk by macOS — it is
/// simply not drawn, so the entire readout vanishes and the app looks dead.
/// Rather than let that happen, the readout gives ground in steps: ornament
/// first, then whole metrics, always from the least important end.
///
/// Importance is the order of `menuBar` in the config file. The first entry is
/// the one worth keeping when there is room for nothing else, which is why it
/// is also the one drawn leftmost — display order and priority are the same
/// list, so there is only one thing to configure.
struct MenuBarLayout: Equatable {
    struct Item: Equatable {
        var metric: Metric
        var style: Metric.Style
    }

    var items: [Item]

    private static let horizontalPadding: CGFloat = 5

    /// Tighter once anything is compact: the gaps are ornament too, and at that
    /// point every point is worth having.
    var spacing: CGFloat {
        items.contains { $0.style == .compact } ? 6 : 9
    }

    /// The status item length this layout needs.
    var width: CGFloat {
        guard !items.isEmpty else { return 26 }
        let blocks = items.reduce(0) { $0 + $1.metric.width($1.style) }
        let gaps = CGFloat(items.count - 1) * spacing
        return blocks + gaps + Self.horizontalPadding * 2
    }

    var metrics: [Metric] { items.map(\.metric) }

    /// Every layout worth showing, richest first.
    ///
    /// The order encodes one judgement: more metrics beats more detail. Four
    /// compact readings say more about the machine than two full ones, because
    /// what a compact block loses is decoration rather than information.
    ///
    /// Built once per config change rather than per fit check — the widths are
    /// fixed, so only the amount of space available varies.
    static func ladder(for metrics: [Metric]) -> [MenuBarLayout] {
        guard !metrics.isEmpty else { return [MenuBarLayout(items: [])] }

        var result: [MenuBarLayout] = []
        for kept in stride(from: metrics.count, through: 1, by: -1) {
            let shown = metrics.prefix(kept)
            for compacted in 0...kept {
                // Compaction spreads from the least important end inwards, so
                // the first metric keeps its full form longest.
                let items = shown.enumerated().map { index, metric in
                    Item(metric: metric, style: index >= kept - compacted ? .compact : .full)
                }
                result.append(MenuBarLayout(items: items))
            }
        }
        return result
    }

    /// Position in the ladder of the richest layout that fits, or of the
    /// poorest one there is.
    ///
    /// Falling back to the poorest rather than to nothing is deliberate: when
    /// even one compact metric will not fit, macOS hides the item either way,
    /// and this way the readout reappears the moment any space frees up.
    ///
    /// A position rather than the layout itself, because the ladder is not
    /// ordered by width — four compact metrics are narrower than three full
    /// ones but sit above them — so position is the only honest measure of one
    /// layout being richer than another.
    static func fittingIndex(in ladder: [MenuBarLayout], within available: CGFloat) -> Int {
        ladder.firstIndex { $0.width <= available } ?? ladder.count - 1
    }
}

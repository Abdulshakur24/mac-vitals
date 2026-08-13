import Foundation

/// Compact, fixed-width-friendly number formatting.
///
/// Everything here aims for short strings of stable length. The menu bar item
/// resizes itself to fit its content, so a formatter that returns "9.9 MB/s"
/// one tick and "10.12 MB/s" the next makes the whole right side of the menu
/// bar shuffle sideways.
enum Format {
    /// Bytes as a size, e.g. "1.4 GB". Always 1 decimal above KB.
    static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = Double(value)
        var unit = 0
        while amount >= 1024, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        if unit == 0 { return "\(Int(amount)) B" }
        return String(format: "%.1f %@", amount, units[unit])
    }

    /// Bytes per second, e.g. "12.4 MB/s". Rounds to whole numbers above
    /// 100 so the string never exceeds "999 MB/s" in width.
    static func rate(_ bytesPerSecond: Double) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var amount = max(0, bytesPerSecond)
        var unit = 0
        while amount >= 1024, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        if unit == 0 { return "\(Int(amount)) B/s" }
        if amount >= 100 { return String(format: "%.0f %@/s", amount, units[unit]) }
        return String(format: "%.1f %@/s", amount, units[unit])
    }

    /// Bytes per second in as few characters as carry the magnitude, e.g.
    /// "12M". No unit word and no "/s": in a stacked pair of rows under an
    /// arrow, both are inferable from the context and neither is worth the
    /// points they cost when the menu bar is full.
    static func compactRate(_ bytesPerSecond: Double) -> String {
        // Kilobytes are the floor rather than bytes: a bare byte count sits
        // under a "3.0K" in the row above reading "1005", which looks like the
        // larger of the two. Below a kilobyte nothing is happening anyway.
        let units = ["K", "M", "G"]
        var amount = max(0, bytesPerSecond) / 1024
        var unit = 0
        while amount >= 1024, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        // One decimal only below 10, where it is the difference between "1M"
        // and "9M" covering everything from a trickle to a saturated link.
        if amount < 10 { return String(format: "%.1f%@", amount, units[unit]) }
        return String(format: "%.0f%@", amount, units[unit])
    }

    /// A 0...1 fraction as a whole percentage, e.g. "42%".
    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// Degrees with no decimal, e.g. "62°".
    static func celsius(_ value: Double) -> String {
        "\(Int(value.rounded()))°"
    }

    /// Gigabytes with one decimal, for memory readouts, e.g. "9.8G".
    static func gigabytes(_ value: UInt64) -> String {
        String(format: "%.1fG", Double(value) / 1_073_741_824)
    }

    /// Gigabytes rounded to whole units, e.g. "10G". The decimal is the first
    /// thing worth losing on a crowded menu bar: memory used moves in hundreds
    /// of megabytes, and a tenth of a gigabyte is below the resolution anyone
    /// reads it at.
    static func wholeGigabytes(_ value: UInt64) -> String {
        String(format: "%.0fG", Double(value) / 1_073_741_824)
    }
}

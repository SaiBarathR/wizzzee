import Foundation

/// Byte and count formatting.
///
/// Sizes are shown base-10 (1 GB = 1,000,000,000 bytes) to line up with what
/// Finder and "Get Info" report, so numbers here can be compared against the
/// rest of the system without conversion. Note this differs from WizTree on
/// Windows, which labels base-2 units "GB".
enum ByteFormat {
    private static let decimalUnits = ["bytes", "KB", "MB", "GB", "TB", "PB"]
    private static let binaryUnits = ["bytes", "KiB", "MiB", "GiB", "TiB", "PiB"]

    static func decimal(_ bytes: UInt64) -> String {
        format(bytes, divisor: 1000, units: decimalUnits)
    }

    static func binary(_ bytes: UInt64) -> String {
        format(bytes, divisor: 1024, units: binaryUnits)
    }

    private static func format(
        _ bytes: UInt64,
        divisor: Double,
        units: [String]
    ) -> String {
        if bytes == 0 { return "0 bytes" }
        if bytes < UInt64(divisor) { return "\(bytes) \(units[0])" }

        var value = Double(bytes)
        var unit = 0
        while value >= divisor && unit < units.count - 1 {
            value /= divisor
            unit += 1
        }
        // One decimal below 100, none above — keeps columns narrow while staying
        // precise where the difference is worth reading.
        let digits = value < 100 ? 1 : 0
        return String(format: "%.\(digits)f %@", value, units[unit])
    }

    /// Thousands-separated integer, for item/file/folder counts.
    static func count(_ value: Int) -> String {
        countFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    /// Abbreviated count for narrow columns: 2760 -> "2.8k", 469687 -> "470k".
    ///
    /// Grouped counts are locale-dependent and can be wide — Indian grouping
    /// renders 469,687 as "4,69,687" — which does not fit the legend's column.
    static func compactCount(_ value: Int) -> String {
        if value < 1000 { return String(value) }
        if value < 1_000_000 {
            let thousands = Double(value) / 1000
            return thousands < 10
                ? String(format: "%.1fk", thousands)
                : String(format: "%.0fk", thousands)
        }
        let millions = Double(value) / 1_000_000
        return millions < 10
            ? String(format: "%.1fM", millions)
            : String(format: "%.0fM", millions)
    }

    static func percent(_ fraction: Double) -> String {
        if !fraction.isFinite { return "0.0 %" }
        let value = fraction * 100
        if value > 0 && value < 0.1 { return "< 0.1 %" }
        return String(format: "%.1f %%", value)
    }

    /// Elapsed scan time, matching WizTree's "Scan complete in 3.17 seconds".
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return String(format: "%.0f ms", seconds * 1000)
        }
        if seconds < 60 {
            return String(format: "%.2f seconds", seconds)
        }
        let minutes = Int(seconds) / 60
        let remainder = seconds - Double(minutes * 60)
        return String(format: "%dm %.1fs", minutes, remainder)
    }

    static func date(_ timestamp: Double) -> String {
        guard timestamp > 0 else { return "" }
        return dateFormatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

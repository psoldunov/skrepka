import Foundation

/// A byte count as the picker subtitle shows it: decimal units, the way
/// `ByteCountFormatStyle(style: .file)` renders on macOS, so a Linux row and a
/// Mac row describe the same file the same way.
///
/// Spelled out rather than taken from Foundation so it is deterministic across
/// locales and needs no `NumberFormatter` — a kilobyte is 1000 bytes, matching
/// Finder's Get Info, and a whole number drops its trailing ".0".
enum DecimalByteCount {
    private static let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]

    /// `bytes` rendered as "512 bytes", "1 byte", "1.5 MB".
    static func string(_ bytes: Int) -> String {
        guard bytes != 1 else { return "1 byte" }
        guard bytes >= 1000 else { return "\(bytes) bytes" }
        var value = Double(bytes)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return "\(trimmed(value)) \(units[unit])"
    }

    /// One decimal place, with a trailing ".0" removed — "1.5", "512", "2".
    private static func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded(.down) {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }
}

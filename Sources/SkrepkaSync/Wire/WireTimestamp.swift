import Foundation

/// Every instant on the wire, as `Int64` milliseconds since the Unix epoch.
///
/// Not `Date`'s own `Codable` form, which is a `Double` of seconds since 2001
/// and means nothing outside Swift, and not a CBOR tag-1 value, whose handling
/// varies by decoder. An integer millisecond count is unambiguous in every
/// language that has to read this, including the JavaScript of the GNOME Shell
/// extension.
public struct WireTimestamp: Sendable, Hashable, Codable, Comparable {
    public let milliseconds: Int64

    public init(milliseconds: Int64) {
        self.milliseconds = milliseconds
    }

    /// Rounds to the nearest millisecond, saturating rather than trapping.
    ///
    /// A `Date` far enough outside the representable range would overflow the
    /// conversion, and a trap on a value that can arrive from storage is a
    /// crash rather than an error. Clamping keeps the comparison total.
    public init(_ date: Date) {
        let scaled = (date.timeIntervalSince1970 * 1000).rounded()
        if let exact = Int64(exactly: scaled) {
            milliseconds = exact
        } else {
            milliseconds = scaled < 0 ? Int64.min : Int64.max
        }
    }

    public var date: Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    /// The same instant a wire round trip would produce.
    ///
    /// Model types normalise their timestamps through this on construction, so
    /// a value that has crossed the wire compares equal to the one that was
    /// sent. Without it a sub-millisecond difference survives every merge and
    /// two peers never quite agree on `createdAt`.
    public static func millisecondPrecision(_ date: Date) -> Date {
        WireTimestamp(date).date
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.milliseconds < rhs.milliseconds }
}

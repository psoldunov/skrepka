import Foundation

/// The wire protocol revision a peer speaks.
///
/// Comparable because the anti-downgrade rule of design §9 is an inequality:
/// refuse a peer whose advertised version is lower than the last one seen from
/// it. Enforcing that is Phase 2's job; carrying the number is this one's.
public struct ProtocolVersion: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let v1 = ProtocolVersion(rawValue: 1)

    /// What this build speaks.
    public static let current = v1

    public var description: String { "v\(rawValue)" }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

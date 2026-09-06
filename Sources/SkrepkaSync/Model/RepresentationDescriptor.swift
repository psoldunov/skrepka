import Foundation

/// One representation an item offers, and how many bytes it is — without the
/// bytes.
///
/// Metadata is eager and payload is lazy, per design §7: 500 items against a
/// 32 MB ceiling is 16 GB of transfer nobody asked for, and nobody pastes 500
/// screenshots. The byte count is what lets a peer decide whether a fetch is
/// worth making before it makes one.
public struct RepresentationDescriptor: Sendable, Hashable, Codable, Comparable {
    public let key: RepresentationKey
    public let byteCount: Int

    public init(key: RepresentationKey, byteCount: Int) {
        self.key = key
        self.byteCount = byteCount
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.key, lhs.byteCount) < (rhs.key, rhs.byteCount)
    }
}

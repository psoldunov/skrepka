import Foundation

/// One clipboard representation, named in the vocabulary both ends can speak.
///
/// `public.utf8-plain-text` is a macOS identifier and does not belong in a
/// protocol a GTK app and a JavaScript extension have to read, so the wire
/// carries IANA media types and each boundary maps to its own keys — see
/// ``RepresentationKeyMap``.
public struct RepresentationKey: Sendable, Hashable, Codable, Comparable {
    /// IANA media type. The vocabulary a GTK app and a JavaScript extension can
    /// both speak.
    public let canonical: String
    /// The originating platform's own key — a macOS UTI, a Linux MIME target.
    /// Carried so a Mac↔Mac round trip is lossless; ignored by anyone else.
    public let origin: String?

    public init(canonical: String, origin: String? = nil) {
        self.canonical = canonical
        self.origin = origin
    }

    /// Ordered so a list of representations can be sorted into a deterministic
    /// shape before it is encoded. Nothing about the protocol depends on the
    /// ordering being meaningful, only on it being the same on both peers.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.canonical, lhs.origin ?? "") < (rhs.canonical, rhs.origin ?? "")
    }
}

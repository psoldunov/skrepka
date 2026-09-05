import Foundation

// swift-crypto re-exports CryptoKit on Apple platforms, so `SHA256` is the same
// algorithm producing the same bytes either way. Spelled conditionally to match
// `ClipItem`, which pins that equivalence with a known-answer test.
#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

/// Stable identity of one device: lowercase hex of SHA-256 over its
/// certificate's DER encoding.
///
/// Derived rather than random on purpose. A separate random id would be a
/// second identity for the same device, and two identities that can disagree
/// are an authentication hole rather than a redundancy. Design §9 described
/// both an `id=` UUID and an `fp=` fingerprint in the discovery record; with a
/// derived id the fingerprint is a *prefix* of the id, so the record carries
/// one key instead of two and the two can never disagree. Syncthing makes the
/// same choice for the same reason.
public struct SyncDeviceID: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    /// Number of hex characters in a full identifier — SHA-256 is 32 bytes.
    public static let hexLength = 64

    /// Number of leading hex characters in the short form shown to a person —
    /// a pairing screen, a peer list, a log line.
    ///
    /// Not a TXT record key: `ServiceDescriptor` carries the full identifier
    /// under `id` and deliberately advertises no separate `fp=`, which
    /// `ServiceDescriptorTests.noSeparateFingerprint` pins.
    public static let fingerprintLength = 16

    /// Lowercase hex, always ``hexLength`` characters.
    public let hex: String

    /// Derives the identifier from a certificate's DER encoding.
    public init(certificateDER: Data) {
        hex = SHA256.hash(data: certificateDER).map { String(format: "%02x", $0) }.joined()
    }

    /// Accepts an identifier that arrived from outside — a TXT record, a
    /// database column, a decoded frame.
    ///
    /// Fails rather than normalises: an identifier that is not exactly 64
    /// lowercase hex characters did not come from ``init(certificateDER:)``,
    /// and silently upper-casing or padding it would let two spellings of one
    /// device compare unequal.
    public init?(hex: String) {
        let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
        let letters = UInt8(ascii: "a")...UInt8(ascii: "f")
        guard hex.utf8.count == Self.hexLength,
            hex.utf8.allSatisfy({ digits.contains($0) || letters.contains($0) })
        else { return nil }
        self.hex = hex
    }

    /// The short form for a human to compare: a prefix of ``hex``, never a
    /// separate value, and never what a peer is authenticated against.
    public var fingerprint: String { String(hex.prefix(Self.fingerprintLength)) }

    public var description: String { hex }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.hex < rhs.hex }
}

// MARK: - Codable

extension SyncDeviceID {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let decoded = SyncDeviceID(hex: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Not a 64-character lowercase hex device identifier."
            )
        }
        self = decoded
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

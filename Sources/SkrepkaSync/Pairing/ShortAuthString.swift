import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

/// The eight hex characters both devices display during pairing, rendered
/// `A3F2-91BC`.
///
/// This is the entire man-in-the-middle defence. TLS at first contact can only
/// prove that the two ends share a tunnel, not that the far end is the laptop
/// on the desk; a human comparing two strings on two screens is what closes
/// that. Everything about the rendering is in service of being read aloud and
/// compared in three seconds — uppercase, grouped in fours, no characters that
/// need a font to tell apart.
///
/// Both halves of the derivation are lifted from KDE Connect's
/// `pairinghandler.cpp` and both are load-bearing:
///
/// - **Sorting the keys** is what lets the two ends compute the same string
///   without first agreeing which of them is "first". Without it the initiator
///   and the responder hash the same two keys in opposite orders and every
///   pairing looks like an attack.
/// - **The timestamp** is what kills replay. Without it a recorded pairing
///   exchange keeps producing a string the user already approved once, forever.
///
/// **This derivation lets whoever moves second choose its own inputs after
/// seeing the first mover's**, which is why the width below is what it is. See
/// [OQ-15](../../../docs/linux-sync/open-questions.md) for the structural fix —
/// commit-then-reveal — and why it is a change to make before this ships rather
/// than after.
public enum ShortAuthString {
    /// How many hex characters the user compares.
    ///
    /// Sixteen, so 64 bits, rendered `A3F2-91BC-D4E7-0182`.
    ///
    /// **The width is the whole defence, because nothing here commits either
    /// side's inputs.** An attacker relaying a pairing sees the honest device's
    /// key and timestamp before choosing its own: as the responder on one leg it
    /// answers after reading the `pairRequest`, and as the initiator on the
    /// other it picks both a fresh keypair — unbounded — and any `pairedAt`
    /// inside ``SyncLimits/pairingFreshnessWindow``. So it is not guessing a
    /// fixed string once; it is searching for a second preimage with two free
    /// variables, and the only thing bounding that search is how many bits it
    /// has to hit.
    ///
    /// At 32 bits that search was ~2³² hashes of a short input — seconds on one
    /// GPU, comfortably inside the freshness window, which made the
    /// man-in-the-middle this type exists to stop merely expensive rather than
    /// impossible. At 64 it is ~1.8 × 10¹⁹: about 58 years at ten billion hashes
    /// a second, and still hours against a cluster.
    ///
    /// **The width alone is what makes that infeasible.** The attack is online —
    /// the target digest is not known until the honest device sends its
    /// `pairRequest`, and `SyncChannelWiring.pairingReadTimeout` gives that
    /// device up to ``SyncLimits/pairingFreshnessWindow`` to be answered — so
    /// there is a second bound as well. But 64 bits does not lean on it: even an
    /// attacker who could hold the honest side open indefinitely, or who ground
    /// offline for a week, would not get there. Do not read the two constants as
    /// jointly load-bearing and shorten one because the other looks generous.
    ///
    /// What is *not* true, and was written here before, is that the window keeps
    /// an attacker to a single attempt. It bounds how long a search may run; it
    /// does not make the search a guess.
    public static let hexDigitCount = 16

    /// Characters per rendered group.
    public static let groupSize = 4

    /// How long the grouped string is, separators included.
    ///
    /// Here rather than counted at each call site, because two things depend on
    /// it that are nowhere near each other: `PairingSheet` sizes its one line to
    /// hold exactly this many characters, and the suites that check a proposal
    /// carries a code assert against it rather than spelling a number that a
    /// change to ``hexDigitCount`` would leave stale in four files.
    public static var renderedLength: Int {
        hexDigitCount + (hexDigitCount - 1) / groupSize
    }

    /// Derives the string both ends display.
    ///
    /// - Parameters:
    ///   - publicKeys: both devices' public keys, in either order. They are
    ///     sorted here.
    ///   - pairedAt: the instant carried in the `pairRequest`, at millisecond
    ///     precision so both ends hash the same integer whatever their
    ///     `Date` resolution.
    public static func derive(publicKeys: [Data], pairedAt: Date) -> String {
        var hasher = SHA256()
        for key in publicKeys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            hasher.update(data: key)
        }
        hasher.update(data: timestampBytes(pairedAt))

        let hex = hasher.finalize()
            .prefix(hexDigitCount / 2)
            .map { String(format: "%02X", $0) }
            .joined()
        return grouped(hex)
    }

    /// Big-endian milliseconds since the epoch — the same integer the wire
    /// carries, so a peer that read the timestamp off a frame hashes exactly
    /// what the sender hashed.
    static func timestampBytes(_ date: Date) -> Data {
        withUnsafeBytes(of: WireTimestamp(date).milliseconds.bigEndian) { Data($0) }
    }

    /// `A3F291BC` → `A3F2-91BC`.
    static func grouped(_ hex: String) -> String {
        stride(from: 0, to: hex.count, by: groupSize)
            .map { offset in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                let end = hex.index(start, offsetBy: groupSize, limitedBy: hex.endIndex) ?? hex.endIndex
                return String(hex[start..<end])
            }
            .joined(separator: "-")
    }
}

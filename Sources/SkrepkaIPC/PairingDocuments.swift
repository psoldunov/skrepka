import Foundation

/// The pairing listener's state after ``SkrepkaInterface/Member/openPairing``.
public struct PairingWindowDocument: SkrepkaDocument, Hashable {
    public let version: UInt32

    /// The port the pairing listener bound, and therefore the `pair=` key a
    /// peer now sees in this device's advertisement.
    public let port: UInt16

    /// When the window closes by itself.
    ///
    /// Bounded rather than open because the pairing listener is by construction
    /// the one that accepts a certificate nobody has approved yet. A window
    /// left open is the only moment a stranger on the LAN can complete a
    /// handshake at all, so it closes whether or not anyone remembers to.
    public let expiresAt: Date

    public init(port: UInt16, expiresAt: Date, version: UInt32 = SkrepkaInterface.version) {
        self.version = version
        self.port = port
        self.expiresAt = expiresAt
    }
}

/// A pairing waiting for a human to compare words.
///
/// Carried both as the answer to ``SkrepkaInterface/Member/pairWith`` — this
/// device dialled — and on ``SkrepkaInterface/Signal/pairingRequested`` — a
/// peer dialled this device. The same document either way, because the thing
/// the user does is the same: read six words, check they match the other
/// screen, say yes or no.
public struct PairingProposalDocument: SkrepkaDocument, Hashable {
    public let version: UInt32

    /// The peer's identity, and what ``SkrepkaInterface/Member/confirmPairing``
    /// takes back. Full hex rather than the fingerprint: the answer must name
    /// exactly one device, and two proposals in flight with colliding
    /// fingerprints would otherwise both be answered by one call.
    public let deviceID: String

    /// The short form, for showing next to the words.
    public let fingerprint: String

    /// What the peer calls itself. Nil on the dialling side, where nothing has
    /// been learned about the peer but its certificate — a
    /// pairing-policy connection may not carry `hello`.
    public let name: String?

    public let platform: String

    /// The short authentication string. **The whole security of pairing is that
    /// a person reads this on both screens and they match** — it is derived
    /// from both certificates, so an attacker in the middle produces two
    /// different strings and the user sees it.
    public let shortAuthString: String

    /// Which way the connection went. `incoming` means a peer dialled here.
    public let direction: String

    /// When the daemon stops waiting and answers `false` on the caller's
    /// behalf.
    ///
    /// A proposal parks a task inside the responder, and on a daemon nobody is
    /// watching there may be no client to answer it — so the wait is bounded
    /// and refusal is the default. A dropped continuation is a task suspended
    /// for the life of the process.
    public let expiresAt: Date

    public init(
        deviceID: String,
        fingerprint: String,
        name: String?,
        platform: String,
        shortAuthString: String,
        direction: String,
        expiresAt: Date,
        version: UInt32 = SkrepkaInterface.version
    ) {
        self.version = version
        self.deviceID = deviceID
        self.fingerprint = fingerprint
        self.name = name
        self.platform = platform
        self.shortAuthString = shortAuthString
        self.direction = direction
        self.expiresAt = expiresAt
    }

    public enum Direction {
        public static let incoming = "incoming"
        public static let outgoing = "outgoing"
    }
}

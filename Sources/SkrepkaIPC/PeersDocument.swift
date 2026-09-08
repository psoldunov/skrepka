import Foundation

/// One device, paired or merely visible.
///
/// Both in one type rather than two lists, because the question a user asks is
/// "where is my other machine" and the answer runs across the boundary: a peer
/// that is paired but not sighted has gone off the network, and one that is
/// sighted but not paired is waiting to be paired with. Two lists make the
/// reader join them.
public struct PeerDocument: Codable, Sendable, Hashable {
    /// SHA-256 of the peer's certificate DER, lowercase hex. Its identity.
    public let deviceID: String

    /// The short form, which is what a user compares and what
    /// ``SkrepkaInterface/Member/pairWith`` takes.
    public let fingerprint: String

    /// From the peer's `hello` where the link has been up, from its
    /// advertisement otherwise, and nil where neither has happened.
    public let name: String?

    /// `macos`, `linux`, or `unknown`. Decides the live-push default.
    public let platform: String

    public let isPaired: Bool

    /// Whether the peer is advertising on the local network right now.
    public let isSighted: Bool

    /// Whether the peer says it will accept a pairing dial. Only meaningful
    /// while ``isSighted``.
    public let isAcceptingPairing: Bool

    /// What the outbound link is doing: `idle`, `connecting`, `connected`,
    /// `synced`, `pushed`, or a `failed: …` line. A string rather than an enum
    /// for the reason ``ClipDocument/kind`` is one.
    public let linkState: String

    /// Whether live push is on for this peer, after the per-peer override has
    /// been resolved against the platform default.
    public let livePush: Bool

    /// The last successful index exchange, or nil where there has not been one
    /// this run.
    public let lastSyncedAt: Date?

    // Deliberately absent: the offset between this device's clock and the
    // peer's. The phase plan asks for it, and Skrepka's wire protocol carries
    // no timestamp in `hello`, so there is nothing to compare against without a
    // protocol change. A field that is structurally always nil would read as
    // "no skew" when it means "never measured", which is worse than an absent
    // one. `ClockCheck` answers the local half of the question honestly, and
    // `DiagnosticsDocument.problems` is where its answer appears.

    public init(
        deviceID: String,
        fingerprint: String,
        name: String?,
        platform: String,
        isPaired: Bool,
        isSighted: Bool,
        isAcceptingPairing: Bool,
        linkState: String,
        livePush: Bool,
        lastSyncedAt: Date?
    ) {
        self.deviceID = deviceID
        self.fingerprint = fingerprint
        self.name = name
        self.platform = platform
        self.isPaired = isPaired
        self.isSighted = isSighted
        self.isAcceptingPairing = isAcceptingPairing
        self.linkState = linkState
        self.livePush = livePush
        self.lastSyncedAt = lastSyncedAt
    }
}

/// The answer to ``SkrepkaInterface/Member/peers``.
public struct PeersDocument: SkrepkaDocument, Hashable {
    public let version: UInt32

    /// This device, so a user comparing fingerprints across two machines has
    /// both halves without running a second command.
    public let localDeviceID: String
    public let localFingerprint: String
    public let localName: String

    /// Paired peers first, then sighted-but-unpaired. Within each group, by
    /// name.
    public let peers: [PeerDocument]

    /// Whether this device is currently accepting pairing dials, and on which
    /// port. Nil when the window is closed.
    public let pairingPort: UInt16?

    public init(
        localDeviceID: String,
        localFingerprint: String,
        localName: String,
        peers: [PeerDocument],
        pairingPort: UInt16?,
        version: UInt32 = SkrepkaInterface.version
    ) {
        self.version = version
        self.localDeviceID = localDeviceID
        self.localFingerprint = localFingerprint
        self.localName = localName
        self.peers = peers
        self.pairingPort = pairingPort
    }
}

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

    /// What the user chose for this peer, as one of ``LivePushChoiceName``.
    ///
    /// Nil for a device that is not paired — live push to one is impossible,
    /// not merely off — and in a document from a daemon older than interface
    /// version 2. Carried beside ``livePush`` rather than instead of it
    /// because a settings row shows both: the switch follows ``livePush``,
    /// and the sentence under it depends on whether the user has chosen at all.
    public let livePushChoice: String?

    /// Why live push is on or off while the user has chosen nothing, as one of
    /// ``LivePushDefaultName``. Nil wherever ``livePushChoice`` is.
    ///
    /// Sent rather than rebuilt by each client from the two platforms, which
    /// would be design §3's rule written once per client — and a client that
    /// lags the daemon would then state a default the daemon no longer applies.
    public let livePushDefault: String?

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
        lastSyncedAt: Date?,
        livePushChoice: String? = nil,
        livePushDefault: String? = nil
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
        self.livePushChoice = livePushChoice
        self.livePushDefault = livePushDefault
    }

    /// The values ``livePushChoice`` carries, and what
    /// ``SkrepkaInterface/Member/setLivePush`` accepts.
    ///
    /// The same strings as `LivePushChoice`'s raw values in `SkrepkaSync`,
    /// which this target cannot import — it builds without the sync core so
    /// the CLI does not link it. `LivePushMemberTests` holds the two together.
    public enum LivePushChoiceName {
        /// Nothing recorded; ``PeerDocument/livePushDefault`` decides.
        public static let followsPlatformDefault = "followsPlatformDefault"
        public static let on = "on"
        public static let off = "off"
    }

    /// The values ``livePushDefault`` carries — `LivePushDefault`'s cases.
    public enum LivePushDefaultName {
        /// Two different systems, or two Linux machines: live push is the
        /// point of pairing them.
        public static let on = "on"
        /// Two Apple devices, where Universal Clipboard already does this.
        public static let offBetweenAppleDevices = "offBetweenAppleDevices"
        /// The peer has not said what it runs — on Linux, until its link has
        /// connected this run.
        public static let offForUnrecognisedPlatform = "offForUnrecognisedPlatform"
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

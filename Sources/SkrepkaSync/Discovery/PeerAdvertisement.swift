import Foundation

/// What a peer's TXT record says about it.
///
/// The parsed half of design §9's discovery record. Everything here came off
/// the network unauthenticated — pairing is what turns it into trust — so this
/// type deliberately carries no verdict, only what was advertised.
public struct PeerAdvertisement: Sendable, Hashable {
    /// The peer's identity: the SHA-256 of its certificate's DER encoding, so
    /// pairing can check the certificate presented in the handshake against the
    /// identifier advertised here.
    public let deviceID: SyncDeviceID

    /// The peer's `name=`, or `nil` where it advertised none. A caller with
    /// nothing to show the user should fall back to the DNS-SD instance name,
    /// which always exists.
    public let displayName: String?

    /// `.unknown` when `plat=` is absent or holds a value this build has never
    /// heard of.
    ///
    /// One rule for both, because there is nothing to tell them apart: an
    /// absent platform is exactly as unrecognisable as an unrecognised one, and
    /// ``PeerPlatform`` already says what to do — live push defaults off, and
    /// the peer is still worth talking to.
    public let platform: PeerPlatform

    /// Whatever the peer advertised, including a version released after this
    /// build.
    ///
    /// Accepted rather than rejected. This is the same forward-compatibility
    /// rule `FrameError.unknownMessageType` follows: a peer speaking a newer
    /// protocol is a peer, and refusing to see it at discovery time turns a
    /// negotiable difference into an invisible machine. Read
    /// ``speaksAKnownProtocolVersion`` before deciding what to send it.
    public let protocolVersion: ProtocolVersion

    /// The port to dial to pair with this peer, or `nil` where it advertised
    /// none.
    ///
    /// Absent means the peer is not accepting new pairings — see
    /// ``ServiceDescriptor/pairingPort``. That is a thing to tell the user
    /// rather than a reason to hide the peer, so it is optional here and never
    /// throws for being missing.
    public let pairingPort: UInt16?

    /// Keys the peer advertised that this build has no meaning for, lowercased
    /// and sorted. Worth logging; not worth refusing over.
    public let unrecognisedKeys: [String]

    /// Whether this peer says it will accept a pairing dial right now.
    public var isAcceptingPairing: Bool { pairingPort != nil }

    /// Whether this build has heard of the peer's protocol version.
    public var speaksAKnownProtocolVersion: Bool { protocolVersion <= .current }

    /// The short form of the identifier, for a user-facing pairing screen.
    public var fingerprint: String { deviceID.fingerprint }

    public init(
        deviceID: SyncDeviceID,
        displayName: String?,
        platform: PeerPlatform,
        protocolVersion: ProtocolVersion,
        pairingPort: UInt16? = nil,
        unrecognisedKeys: [String] = []
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.platform = platform
        self.protocolVersion = protocolVersion
        self.pairingPort = pairingPort
        self.unrecognisedKeys = unrecognisedKeys
    }
}

// MARK: - Reading a record

extension PeerAdvertisement {
    /// Reads a peer's record.
    ///
    /// Every failure is thrown with a name. Nothing here returns `nil` or
    /// substitutes a default for a key that is required, because the caller
    /// surfaces the error against the peer it came from and a swallowed one
    /// leaves a machine that is simply missing.
    public init(txtRecord record: TXTRecord) throws {
        let version = try PeerAdvertisement.string(
            in: record, for: ServiceDescriptor.Key.recordVersion, required: true)
        guard version == ServiceDescriptor.recordVersion else {
            throw AdvertisementError.unsupportedRecordVersion(version ?? "")
        }

        let hex = try PeerAdvertisement.string(
            in: record, for: ServiceDescriptor.Key.deviceID, required: true)
        guard let hex, let deviceID = SyncDeviceID(hex: hex) else {
            throw AdvertisementError.malformedValue(
                key: ServiceDescriptor.Key.deviceID,
                reason: "not \(SyncDeviceID.hexLength) lowercase hex characters"
            )
        }

        let rawVersion = try PeerAdvertisement.string(
            in: record, for: ServiceDescriptor.Key.protocolVersion, required: true)
        guard let rawVersion, let number = Int(rawVersion), number > 0 else {
            throw AdvertisementError.malformedValue(
                key: ServiceDescriptor.Key.protocolVersion,
                reason: "not a positive integer"
            )
        }

        let platform = try PeerAdvertisement.string(
            in: record, for: ServiceDescriptor.Key.platform, required: false)
        let displayName = try PeerAdvertisement.string(
            in: record, for: ServiceDescriptor.Key.displayName, required: false)

        self.init(
            deviceID: deviceID,
            displayName: displayName,
            platform: platform.map(PeerPlatform.init(wireValue:)) ?? .unknown,
            protocolVersion: ProtocolVersion(rawValue: number),
            pairingPort: try PeerAdvertisement.pairingPort(in: record),
            unrecognisedKeys: record.keys(outside: ServiceDescriptor.Key.all)
        )
    }

    /// The `pair=` port, or nil when the peer advertised none.
    ///
    /// Absent is ordinary — the peer is not pairing right now. Present and
    /// unparseable is not: a key that is there but does not name a port is a
    /// record this build cannot act on, and reading it as "not pairing" would
    /// hide a broken peer behind an ordinary-looking state. Zero is refused with
    /// the rest, since no listener binds it.
    private static func pairingPort(in record: TXTRecord) throws -> UInt16? {
        guard
            let raw = try PeerAdvertisement.string(
                in: record, for: ServiceDescriptor.Key.pairingPort, required: false)
        else { return nil }
        guard let port = UInt16(raw), port > 0 else {
            throw AdvertisementError.malformedValue(
                key: ServiceDescriptor.Key.pairingPort,
                reason: "not a TCP port"
            )
        }
        return port
    }

    /// Reads the record's raw bytes, for a caller holding the DNS-SD wire form
    /// rather than a parsed record.
    public init(dnsSDWireFormat data: Data) throws {
        do {
            try self.init(txtRecord: TXTRecord(dnsSDWireFormat: data))
        } catch let error as TXTRecordError {
            throw AdvertisementError.malformedRecord(reason: error.description)
        }
    }

    /// One value as UTF-8 text.
    ///
    /// A key present with no value at all — `key` rather than `key=`, which
    /// RFC 6763 §6.4 distinguishes — reads as missing rather than as empty,
    /// because none of this record's keys means anything without a value.
    private static func string(
        in record: TXTRecord,
        for key: String,
        required: Bool
    ) throws -> String? {
        guard let entry = record.entry(for: key), entry.value != nil else {
            guard required else { return nil }
            throw AdvertisementError.missingKey(key)
        }
        guard let text = entry.stringValue else {
            throw AdvertisementError.malformedValue(key: key, reason: "not UTF-8")
        }
        return text
    }
}

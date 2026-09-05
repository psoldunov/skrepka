import Foundation

/// What this device publishes on the local network.
///
/// The TXT record is design §9's, minus its `fp=` key. Phase 1 folded the
/// fingerprint into the identifier — ``SyncDeviceID`` *is* the SHA-256 of the
/// certificate's DER encoding, so `fp=` would be a prefix of `id=` rather than
/// a second fact, and two identities that can disagree are an authentication
/// hole. `SyncDeviceID.fingerprint` is where the short form now lives.
public struct ServiceDescriptor: Sendable, Hashable {
    /// DNS-SD service type. Design §9: the Service Name is `skrepka`, seven
    /// characters, inside the fifteen RFC 6763 §7.2 allows — the leading
    /// underscore is not counted.
    public static let serviceType = "_skrepka._tcp"

    /// The value of `txtvers`. RFC 6763 §6.7 makes it the first key of a record
    /// and the one a reader checks before trusting any grammar below it.
    public static let recordVersion = "1"

    /// A DNS label is at most 63 octets, and RFC 6763 §4.1.1 makes the service
    /// instance name exactly one label. A longer display name is clamped rather
    /// than refused: the name is a human label, and refusing to advertise
    /// because a Mac is called something long would take the device off the
    /// network over cosmetics.
    public static let maximumDisplayNameBytes = 63

    /// Every key this build writes, so the reader can name the rest as
    /// unrecognised rather than guessing at them.
    public enum Key {
        public static let recordVersion = "txtvers"
        public static let deviceID = "id"
        public static let displayName = "name"
        public static let protocolVersion = "proto"
        public static let platform = "plat"

        public static let all: Set<String> = [
            recordVersion, deviceID, displayName, protocolVersion, platform,
        ]
    }

    /// The human label, clamped to ``maximumDisplayNameBytes``. Used both as
    /// the DNS-SD instance name and as the record's `name=` value.
    ///
    /// Empty means "let the responder choose", which on macOS is the computer's
    /// own name. That is a better answer than an empty instance name, which
    /// DNS-SD does not allow. An empty name also leaves `name=` out of the
    /// record entirely — see ``txtRecord()``.
    public let displayName: String

    /// The TCP port the sync transport is already listening on.
    ///
    /// Already listening, not about to: on macOS the advertisement is published
    /// by `DNSServiceRegister`, which registers a record for a port someone
    /// else owns and binds nothing itself. See ``BonjourDiscovery`` for why
    /// that matters.
    public let port: UInt16

    public let deviceID: SyncDeviceID
    public let platform: PeerPlatform
    public let protocolVersion: ProtocolVersion

    public init(
        displayName: String,
        port: UInt16,
        deviceID: SyncDeviceID,
        platform: PeerPlatform,
        protocolVersion: ProtocolVersion = .current
    ) {
        self.displayName = ServiceDescriptor.clamped(displayName)
        self.port = port
        self.deviceID = deviceID
        self.platform = platform
        self.protocolVersion = protocolVersion
    }

    /// The record to advertise.
    ///
    /// Throws rather than trimming. Every value here is bounded by
    /// construction — 64 hex characters of identifier, a display name already
    /// clamped to 63 bytes, two short integers and a platform name — so a throw
    /// means an invariant broke, and quietly shortening the identifier in that
    /// case would advertise a device that is not this one.
    ///
    /// An empty ``displayName`` leaves `name=` out rather than writing it
    /// empty. RFC 6763 §6.4 makes "no such key" and "key with an empty value"
    /// two different statements, and only the first one is true here: a peer
    /// reading `name=` gets an empty string, which is a name, so
    /// ``PeerAdvertisement/displayName`` reads `""` and the fallback to the
    /// DNS-SD instance name that field documents never fires. The instance name
    /// is exactly what an empty display name asked the responder to choose, so
    /// the fallback is the whole point.
    public func txtRecord() throws -> TXTRecord {
        var entries = [
            try TXTRecord.Entry(key: Key.recordVersion, value: ServiceDescriptor.recordVersion),
            try TXTRecord.Entry(key: Key.deviceID, value: deviceID.hex),
        ]
        if !displayName.isEmpty {
            entries.append(try TXTRecord.Entry(key: Key.displayName, value: displayName))
        }
        entries.append(
            try TXTRecord.Entry(key: Key.protocolVersion, value: String(protocolVersion.rawValue)))
        entries.append(try TXTRecord.Entry(key: Key.platform, value: platform.rawValue))
        return try TXTRecord(entries)
    }

    /// Truncates on a character boundary, so a clamp never splits a grapheme
    /// into bytes that are not text.
    static func clamped(_ name: String) -> String {
        guard name.utf8.count > maximumDisplayNameBytes else { return name }
        var clamped = ""
        var bytes = 0
        for character in name {
            let size = String(character).utf8.count
            guard bytes + size <= maximumDisplayNameBytes else { break }
            clamped.append(character)
            bytes += size
        }
        return clamped
    }
}

import Foundation

/// A device this one has paired with, as a `TrustStore` remembers it.
///
/// ``deviceID`` is *derived* rather than accepted, so a record whose identifier
/// and certificate disagree cannot be constructed. That is the one invariant
/// worth enforcing in the type: the identifier is the pin, and a pin that does
/// not match the bytes it pins would authenticate a device that never presented
/// this certificate.
public struct PairedPeer: Sendable, Hashable {
    /// SHA-256 of ``certificateDER``, derived on construction.
    public let deviceID: SyncDeviceID
    /// What the user sees. Advisory, and the peer may change it.
    public let deviceName: String
    public let platform: PeerPlatform
    /// The certificate shown at pairing time. Pinning compares a peer's leaf
    /// against the hash of these bytes and nothing else.
    public let certificateDER: Data
    public let pairedAt: Date

    public init(certificateDER: Data, deviceName: String, platform: PeerPlatform, pairedAt: Date) {
        deviceID = SyncDeviceID(certificateDER: certificateDER)
        self.certificateDER = certificateDER
        self.deviceName = deviceName
        self.platform = platform
        self.pairedAt = WireTimestamp.millisecondPrecision(pairedAt)
    }

    /// The same peer under a new display name.
    ///
    /// The certificate is what carries forward, so the identifier does not
    /// move: a user renaming their laptop must not read as a different device.
    public func renamed(_ deviceName: String) -> PairedPeer {
        PairedPeer(
            certificateDER: certificateDER,
            deviceName: deviceName,
            platform: platform,
            pairedAt: pairedAt
        )
    }
}

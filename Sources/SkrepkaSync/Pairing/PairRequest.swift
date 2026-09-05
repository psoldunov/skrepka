import Foundation

/// What a device asks for on first contact, as carried in a `pairRequest`.
///
/// A type rather than five associated values on the message case, so the fields
/// travel together: ``PairingSession/proposal(for:presentedCertificateDER:now:)``
/// checks three of them against each other — and ``certificateDER`` against the
/// certificate the tunnel actually presented — and a caller that had to restate
/// the list could restate it wrongly.
///
/// ``deviceID`` is claimed as well as derivable from ``certificateDER``. The
/// receiver derives it again and refuses a mismatch, which is what stops a peer
/// from announcing an identity whose private key it does not hold.
public struct PairRequest: Sendable, Hashable {
    public let deviceID: SyncDeviceID
    public let deviceName: String
    public let platform: PeerPlatform
    public let certificateDER: Data
    /// Normalised to millisecond precision by the wire layer; compared against
    /// the receiver's clock under ``SyncLimits/pairingFreshnessWindow``.
    public let pairedAt: Date

    public init(
        deviceID: SyncDeviceID,
        deviceName: String,
        platform: PeerPlatform,
        certificateDER: Data,
        pairedAt: Date
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.platform = platform
        self.certificateDER = certificateDER
        self.pairedAt = pairedAt
    }
}

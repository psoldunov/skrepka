import Foundation

/// Why a tunnel was refused, at configuration time or during the handshake.
public enum SyncTLSError: Error, Sendable, Hashable, CustomStringConvertible {
    /// A `TLSConfiguration` whose `certificateVerification` is
    /// `CertificateVerification/none`, in either of its two spellings.
    ///
    /// This is the trap `swift-nio-ssl` documents on both handler
    /// initialisers: *"The callback will not be used if the `TLSConfiguration`
    /// that was used to construct the `NIOSSLContext` has
    /// `certificateVerification` set to `CertificateVerification/none`."* Such
    /// a connection completes, looks healthy, and verifies nothing — and
    /// `TLSConfiguration.makeServerConfiguration(certificateChain:privateKey:)`
    /// produces exactly it. Refused at construction so it cannot be reached by
    /// picking the wrong factory.
    ///
    /// `optionalVerification` is refused for the same reason: it is
    /// `.none` with presented certificates validated, so a peer that presents
    /// no certificate at all is still accepted, and mutual authentication that
    /// is optional is not mutual authentication.
    case verificationDisabled

    /// A configuration that would accept TLS below 1.3.
    case minimumVersionTooLow(TLSVersionDescription)

    /// The peer presented no certificate.
    case emptyCertificateChain

    /// The peer's leaf could not be re-encoded to DER, so no pin can be
    /// computed for it.
    case peerCertificateUnreadable

    /// The peer's leaf is well formed and is not one of the pinned
    /// identifiers.
    case unpinnedCertificate(SyncDeviceID)

    /// The connection closed before the TLS handshake finished.
    case handshakeIncomplete

    /// The peer completed TCP and did not finish the TLS handshake inside
    /// ``SyncServer/handshakeTimeout``.
    ///
    /// `swift-nio-ssl` 2.37.4 has no handshake deadline of its own, so without
    /// one imposed from outside a peer that connects and then says nothing holds
    /// its half of the listener forever, which is a file descriptor an attacker
    /// spends nothing to take.
    case handshakeTimedOut

    public var description: String {
        switch self {
        case .verificationDisabled:
            "refusing a TLS configuration with certificate verification disabled: "
                + "the pinning callback would never run"
        case .minimumVersionTooLow(let version):
            "refusing a TLS configuration whose minimum version is \(version.rawValue), not TLS 1.3"
        case .emptyCertificateChain:
            "the peer presented no certificate"
        case .peerCertificateUnreadable:
            "the peer's certificate could not be re-encoded to DER"
        case .unpinnedCertificate(let deviceID):
            "the peer's certificate hashes to \(deviceID), which is not pinned"
        case .handshakeIncomplete:
            "the connection closed before the TLS handshake completed"
        case .handshakeTimedOut:
            "the peer did not complete the TLS handshake in time"
        }
    }
}

/// A `NIOSSL.TLSVersion` rendered as a value this target can compare and hash.
///
/// `TLSVersion` is `Hashable` but not `CustomStringConvertible`, and carrying
/// the raw name keeps ``SyncTLSError`` free of a `NIOSSL` import in every file
/// that catches one.
public struct TLSVersionDescription: Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

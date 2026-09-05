import Foundation

/// Why a device identity could not be read or built.
///
/// All four are configuration failures rather than protocol failures: they say
/// something is wrong with what this device has stored, not with what a peer
/// sent. That distinction matters at the call site, because the answer to one
/// is "re-pair" and the answer to the other is "hang up".
public enum DeviceCertificateError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The bytes are not a DER-encoded X.509 certificate.
    case unreadableCertificate(reason: String)

    /// The bytes are not a PEM-encoded P-256 private key.
    case unreadablePrivateKey(reason: String)

    /// The key and the certificate are both readable and belong to different
    /// identities. A handshake with this pair fails inside BoringSSL, so it is
    /// refused here where the message can say why.
    case keyDoesNotMatchCertificate

    public var description: String {
        switch self {
        case .unreadableCertificate(let reason):
            "device certificate could not be decoded: \(reason)"
        case .unreadablePrivateKey(let reason):
            "device private key could not be decoded: \(reason)"
        case .keyDoesNotMatchCertificate:
            "the stored private key does not belong to the stored certificate"
        }
    }
}

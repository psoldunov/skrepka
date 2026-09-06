import Foundation
import SwiftASN1
import X509

// swift-crypto re-exports CryptoKit on Apple platforms. Spelled conditionally
// to match ``SyncDeviceID``, which pins that equivalence with a known-answer
// test.
#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

/// This device's own key pair and self-signed certificate, and the
/// ``SyncDeviceID`` derived from it.
///
/// **Identity is the stored bytes, never a recomputation.** ECDSA signing draws
/// a random nonce, so generating a certificate twice from the *same* private
/// key, serial number and validity window produces different DER and therefore
/// a different ``SyncDeviceID`` — measured, see `open-questions.md#oq-6`. Every
/// initialiser here derives the identifier from the DER it was handed, and
/// ``generate(now:)`` is the only thing in the type that produces new bytes. A
/// device that regenerates its certificate has changed identity and has to be
/// re-paired; that is correct, and it has to be deliberate.
public struct DeviceCertificate: Sendable, Hashable {
    /// Subject and issuer common name. Self-signed, so the two are the same.
    ///
    /// Carries no identity: the certificate is pinned by hash, and the name is
    /// only what a human sees in `openssl x509 -text`.
    public static let commonName = "skrepka-device"

    /// The subject alternative name. Present because a TLS stack expects one,
    /// and never checked — hostname verification is off on both sides and the
    /// pin is the whole of the check.
    public static let subjectAlternativeName = "skrepka.local"

    /// How long a generated certificate is valid for.
    ///
    /// Long, because expiry is not a control here: pinned certificates are
    /// trusted by hash and the verification callback overrides BoringSSL's
    /// date checks along with everything else. A shorter window would only
    /// break re-pairing on a clock that had drifted.
    public static let validity: TimeInterval = 60 * 60 * 24 * 365 * 10

    /// Backdating, against a peer whose clock runs behind this one.
    public static let clockSkewAllowance: TimeInterval = 60 * 60 * 24

    /// The certificate, DER-encoded. These exact bytes are what ``deviceID``
    /// hashes and what a peer pins.
    public let certificateDER: Data

    /// The private key, PKCS#8 PEM.
    ///
    /// PEM rather than DER because a `TrustStore` writes this to a keychain
    /// item or to a `0600` file, and both formats round-trip through
    /// BoringSSL — but only PEM is unambiguous about which of the three
    /// encodings of an EC key it holds.
    public let privateKeyPEM: String

    /// SHA-256 of ``certificateDER``.
    public let deviceID: SyncDeviceID

    /// The public key's canonical bytes, which is what the short authentication
    /// string hashes. See ``ShortAuthString``.
    public let publicKeyBytes: Data

    /// Adopts a certificate and key that already exist — read back from a
    /// keychain, a file, or a test fixture.
    ///
    /// Refuses a key that does not match the certificate. That pair cannot
    /// complete a handshake, and finding out at construction beats finding out
    /// as an opaque BoringSSL failure on the first connection.
    public init(certificateDER: Data, privateKeyPEM: String) throws {
        let parsed: Certificate
        do {
            parsed = try Certificate(derEncoded: Array(certificateDER))
        } catch {
            throw DeviceCertificateError.unreadableCertificate(reason: String(describing: error))
        }

        let signingKey: P256.Signing.PrivateKey
        do {
            signingKey = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
        } catch {
            throw DeviceCertificateError.unreadablePrivateKey(reason: String(describing: error))
        }

        guard Certificate.PrivateKey(signingKey).publicKey == parsed.publicKey else {
            throw DeviceCertificateError.keyDoesNotMatchCertificate
        }

        self.certificateDER = certificateDER
        self.privateKeyPEM = privateKeyPEM
        deviceID = SyncDeviceID(certificateDER: certificateDER)
        publicKeyBytes = Data(parsed.publicKey.subjectPublicKeyInfoBytes)
    }

    /// Mints a new identity. Called once per device, by a `TrustStore` that has
    /// nothing stored yet.
    public static func generate(now: Date = Date()) throws -> DeviceCertificate {
        let signingKey = P256.Signing.PrivateKey()
        let privateKey = Certificate.PrivateKey(signingKey)
        let name = try DistinguishedName { CommonName(commonName) }

        // No `signatureAlgorithm:` — it defaults to the key's own
        // `defaultSignatureAlgorithm`, which for P-256 is `ecdsaWithSHA256`.
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(1),
            publicKey: privateKey.publicKey,
            notValidBefore: now - clockSkewAllowance,
            notValidAfter: now + validity,
            issuer: name,
            subject: name,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                SubjectAlternativeNames([.dnsName(subjectAlternativeName)])
            },
            issuerPrivateKey: privateKey
        )

        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return try DeviceCertificate(
            certificateDER: Data(serializer.serializedBytes),
            privateKeyPEM: signingKey.pemRepresentation
        )
    }

    /// The public-key bytes of a certificate that arrived from a peer, for the
    /// short authentication string.
    public static func publicKeyBytes(fromCertificateDER der: Data) throws -> Data {
        do {
            return Data(try Certificate(derEncoded: Array(der)).publicKey.subjectPublicKeyInfoBytes)
        } catch {
            throw DeviceCertificateError.unreadableCertificate(reason: String(describing: error))
        }
    }
}

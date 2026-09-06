import Foundation
import NIOCore
import NIOSSL

/// TLS 1.3 with mutual authentication and certificate pinning, for both
/// platforms.
///
/// One implementation rather than two — this is [D-9]'s single accepted
/// departure from "native on macOS", and the reason is that a pinning callback
/// which silently verifies nothing looks exactly like one that works, so
/// writing it twice doubles the chance of shipping the broken one without
/// doubling anything that would catch it.
public enum SyncTLS {
    // MARK: - Sources

    public static func certificateSource(_ identity: DeviceCertificate) throws -> NIOSSLCertificateSource {
        .certificate(try NIOSSLCertificate(bytes: Array(identity.certificateDER), format: .der))
    }

    public static func privateKeySource(_ identity: DeviceCertificate) throws -> NIOSSLPrivateKeySource {
        .privateKey(try NIOSSLPrivateKey(bytes: Array(identity.privateKeyPEM.utf8), format: .pem))
    }

    // MARK: - Configurations

    /// The listening side.
    ///
    /// Built from `makeServerConfigurationWithMTLS` and never from
    /// `makeServerConfiguration`: the latter sets `certificateVerification`
    /// to `.none`, which stops the server asking for a client certificate at
    /// all *and* stops the pinning callback from ever running. See
    /// ``SyncTLSError/verificationDisabled``.
    ///
    /// `trustRoots` is deliberately empty. The custom callback replaces every
    /// bit of BoringSSL's chain building, so a trust root would be dead weight
    /// that reads as though some certificate authority mattered here.
    public static func serverConfiguration(identity: DeviceCertificate) throws -> TLSConfiguration {
        var configuration = TLSConfiguration.makeServerConfigurationWithMTLS(
            certificateChain: [try certificateSource(identity)],
            privateKey: try privateKeySource(identity),
            trustRoots: .certificates([])
        )
        configuration.minimumTLSVersion = .tlsv13
        configuration.maximumTLSVersion = .tlsv13
        return configuration
    }

    /// The dialling side.
    ///
    /// Presents a certificate chain and a private key like the server does,
    /// because the server demands one: this is mutual authentication, and a
    /// client with no certificate is a client with no identity to pin.
    ///
    /// `.noHostnameVerification` rather than `.fullVerification` because there
    /// is no hostname worth checking — the peer is identified by the hash of
    /// its certificate, and a name in a self-signed subject alternative name is
    /// whatever its holder typed.
    public static func clientConfiguration(identity: DeviceCertificate) throws -> TLSConfiguration {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = .tlsv13
        configuration.maximumTLSVersion = .tlsv13
        configuration.certificateVerification = .noHostnameVerification
        configuration.trustRoots = .certificates([])
        configuration.certificateChain = [try certificateSource(identity)]
        configuration.privateKey = try privateKeySource(identity)
        return configuration
    }

    /// Builds a context, refusing the two configurations that would make the
    /// pinning callback pointless.
    ///
    /// This is the only way a context is built in this target, so neither
    /// mistake is reachable by picking a different factory upstream.
    public static func context(for configuration: TLSConfiguration) throws -> NIOSSLContext {
        switch configuration.certificateVerification {
        case .fullVerification, .noHostnameVerification:
            break
        case .none:
            throw SyncTLSError.verificationDisabled
        }
        guard configuration.minimumTLSVersion == .tlsv13 else {
            throw SyncTLSError.minimumVersionTooLow(
                TLSVersionDescription(rawValue: String(describing: configuration.minimumTLSVersion))
            )
        }
        return try NIOSSLContext(configuration: configuration)
    }

    // MARK: - The pin

    /// The verification callback, and the whole of this project's transport
    /// security.
    ///
    /// Three properties of `swift-nio-ssl` 2.37.4 shape every line of it, all
    /// read from the library's own source:
    ///
    /// 1. **The chain arrives unprocessed.** The library's warning on the
    ///    typealias is that setting this callback *"will override all
    ///    verification logic that BoringSSL provides"*, so the leaf is a
    ///    candidate and never a validated certificate. Nothing here may assume
    ///    a signature, a date or a chain was checked, because none of them was.
    /// 2. **Rejection is a fulfilled promise.** `promise.succeed(.failed)` is
    ///    how a certificate is refused. Failing the promise, or throwing, is
    ///    the mistake to watch for.
    /// 3. **It does not run at all** if the configuration says
    ///    `certificateVerification: .none` — which is why ``context(for:)``
    ///    refuses that configuration before a context exists to attach this to.
    public static func verificationCallback(
        policy: PinPolicy,
        verification: PeerVerification
    ) -> NIOSSLCustomVerificationCallback {
        { chain, promise in
            guard let leaf = chain.first else {
                verification.record(.refused(.emptyCertificateChain))
                promise.succeed(.failed)
                return
            }

            let der: Data
            do {
                der = Data(try leaf.toDERBytes())
            } catch {
                verification.record(.refused(.peerCertificateUnreadable))
                promise.succeed(.failed)
                return
            }

            let deviceID = SyncDeviceID(certificateDER: der)
            if case .pinned(let allowed) = policy, !allowed.contains(deviceID) {
                verification.record(.refused(.unpinnedCertificate(deviceID)))
                promise.succeed(.failed)
                return
            }

            verification.record(.verified(deviceID: deviceID, certificateDER: der))
            promise.succeed(.certificateVerified)
        }
    }
}

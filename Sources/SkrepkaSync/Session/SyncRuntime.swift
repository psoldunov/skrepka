import Foundation
import NIOCore

/// The five things every sync connection needs, built once when sync starts.
///
/// One value rather than five parameters threaded through the listener, the
/// links and the responders. They are never needed separately — anything that
/// makes a connection needs all of them — and passing them singly is how a
/// listener ends up built from one trust store and a link from another.
///
/// `Sendable` and immutable, because it crosses from the main actor into every
/// `PeerLink` actor and every responder task.
public struct SyncRuntime: Sendable {
    /// This device's certificate and key. The identity every connection
    /// presents and every peer pins.
    public let certificate: DeviceCertificate

    /// The local identity as the protocol states it, plus the certificate that
    /// signs for it.
    public let pairing: PairingSession

    /// Where paired peers, their protocol high-water marks and their live-push
    /// choices live.
    public let trust: any TrustStore

    /// The history, as a sync connection is allowed to see it.
    public let store: any HistoryStoring

    /// Shared by the listener and every link.
    ///
    /// One group per process rather than one per connection: a
    /// `MultiThreadedEventLoopGroup` owns real threads, and a laptop with three
    /// paired peers should not run four of them.
    public let group: any EventLoopGroup

    public var deviceID: SyncDeviceID { certificate.deviceID }
    public var platform: PeerPlatform { pairing.localIdentity.platform }

    public init(
        certificate: DeviceCertificate,
        pairing: PairingSession,
        trust: any TrustStore,
        store: any HistoryStoring,
        group: any EventLoopGroup
    ) {
        self.certificate = certificate
        self.pairing = pairing
        self.trust = trust
        self.store = store
        self.group = group
    }
}

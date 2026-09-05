import Foundation
import NIOConcurrencyHelpers

/// Where the TLS verification callback leaves what it decided.
///
/// The callback runs on an event loop and answers by fulfilling a promise, so
/// it cannot return anything to the code that set it up. The two facts that
/// code needs afterwards — which device the tunnel is actually to, or why it
/// was refused — are written here and read once the handshake has finished.
///
/// Carrying the refusal matters as much as carrying the success: BoringSSL
/// reports a rejected certificate as a generic handshake failure, so without
/// this the caller cannot tell an unpinned peer from a network fault, and
/// "unpinned peer" is the one the user has to be told about.
public final class PeerVerification: Sendable {
    public enum Outcome: Sendable, Hashable {
        case verified(deviceID: SyncDeviceID, certificateDER: Data)
        case refused(SyncTLSError)
    }

    private let state = NIOLockedValueBox<Outcome?>(nil)

    public init() {}

    /// What the callback decided, or nil if it never ran — which is itself the
    /// symptom of a configuration with verification disabled.
    public var outcome: Outcome? { state.withLockedValue { $0 } }

    /// The verified peer, or nil if the handshake did not get that far.
    public var verifiedPeer: (deviceID: SyncDeviceID, certificateDER: Data)? {
        guard case .verified(let deviceID, let certificateDER) = outcome else { return nil }
        return (deviceID, certificateDER)
    }

    /// Records the first decision and ignores any later one.
    ///
    /// First rather than last because a renegotiation or a second chain must
    /// not be able to overwrite a refusal with a success.
    func record(_ outcome: Outcome) {
        state.withLockedValue { stored in
            guard stored == nil else { return }
            stored = outcome
        }
    }
}

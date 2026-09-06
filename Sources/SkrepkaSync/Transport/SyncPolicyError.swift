import Foundation

/// A message refused for the connection it is on rather than for anything wrong
/// with the message itself.
///
/// Both cases are the same rule seen from its two ends —
/// ``PinPolicy/pairing`` carries ``PinPolicy/pairingMessages`` and nothing else
/// — and they are separate cases because the two sides mean opposite things
/// about who is at fault. One is a peer that has no business asking; the other
/// is this device about to become that peer.
public enum SyncPolicyError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The peer sent something other than the pairing handshake on a connection
    /// made under ``PinPolicy/pairing``.
    ///
    /// **Fatal to the connection**, unlike the two tolerated cases in
    /// ``FrameError``. Those are forward compatibility: a peer speaking a newer
    /// version sends frames this build cannot read, the frame has been consumed,
    /// and the stream is still on a boundary — so dropping the frame is right
    /// and dropping the connection would be a bug. This is not that. The frame
    /// decoded perfectly and its meaning is understood exactly; what is wrong is
    /// that a peer whose certificate no human has confirmed is asking for
    /// clipboard history. There is no version of this that is a misunderstanding
    /// to be tolerated, so the connection goes rather than the frame.
    case peerSentOutsidePairing(SyncMessageType)

    /// This device tried to send something other than the pairing handshake on a
    /// connection made under ``PinPolicy/pairing``.
    ///
    /// **Fatal to the call and not to the connection**, which is the deliberate
    /// asymmetry with the case above. Nothing has reached the wire, the peer has
    /// done nothing wrong, and the pairing the user is halfway through is still
    /// good — so this is a tripwire on our own code rather than a reason to tear
    /// down a connection a human is looking at.
    case refusedToSendOutsidePairing(SyncMessageType)

    public var description: String {
        switch self {
        case .peerSentOutsidePairing(let type):
            "the peer sent \(type) on a connection that may only pair"
        case .refusedToSendOutsidePairing(let type):
            "refusing to send \(type) on a connection that may only pair"
        }
    }
}

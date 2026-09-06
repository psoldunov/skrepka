import Foundation

/// A peer that overran a limit its connection sets, rather than one that spoke
/// the protocol wrongly or was refused by ``PinPolicy``.
///
/// Separate from ``SyncProtocolError`` because none of these describe a
/// malformed or unexpected message: each one is a perfectly well-formed message
/// that this connection has not granted the peer the right to send. They are
/// all fatal to the connection for the same reason
/// ``SyncPolicyError/peerSentOutsidePairing(_:)`` is — a peer that ignores a
/// limit is not going to stop when asked politely.
public enum SyncTransportError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The peer queued more undrained frames than ``Mailbox`` will hold.
    ///
    /// `autoRead` is on and the event loop decodes whatever arrives, so without
    /// a ceiling a peer can fill memory with frames nobody has asked for —
    /// including while the responder is parked on a pairing sheet, which is
    /// before any policy decision or user approval has happened. The protocol is
    /// strictly turn-taking, so a peer past the cap is not speaking it.
    case inboundQueueOverflow(capacity: Int)

    /// A `payloadRequest` for a content hash this connection was never offered.
    ///
    /// Serving it would answer "do you hold these bytes" for arbitrary hashes,
    /// which is an oracle a peer can walk. Refused rather than answered with an
    /// empty chunk, because an empty chunk is the ordinary answer for a
    /// representation this store has evicted and the two must not read alike.
    case payloadNotOffered(contentHash: String)

    /// A second `pairRequest` on a connection that has already produced a
    /// proposal.
    ///
    /// Each one raises a sheet in front of the user, and a comparison of two
    /// short authentication strings is worth exactly as much as the user's
    /// attention on the tenth prompt. First contact is one request and one
    /// confirm — ``PinPolicy/pairingMessages`` is that sentence — so a second is
    /// not a retry, it is a peer driving the prompt.
    case repeatedPairRequest

    public var description: String {
        switch self {
        case .inboundQueueOverflow(let capacity):
            "the peer queued more than \(capacity) frames without waiting for an answer"
        case .payloadNotOffered(let contentHash):
            "the peer asked for \(contentHash), which this connection was never offered"
        case .repeatedPairRequest:
            "the peer sent a second pairRequest on a connection that has already proposed one"
        }
    }
}

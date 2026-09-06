import Foundation

/// Which peer certificates a connection will accept.
///
/// There are exactly two answers and no third, because the third — "accept
/// anything, we will check later" — is the failure this whole layer exists to
/// prevent.
public enum PinPolicy: Sendable, Hashable {
    /// Accept only a leaf whose DER hashes to one of these identifiers.
    ///
    /// An empty set accepts nothing, which is the right answer for a device
    /// that has paired with nobody.
    case pinned(Set<SyncDeviceID>)

    /// First contact: accept any well-formed leaf and remember which one
    /// arrived.
    ///
    /// **Not a weaker mode with a friendlier name.** A device that has never
    /// met its peer has nothing to pin, so the tunnel here proves only that the
    /// two ends share a connection — the authentication is the human comparing
    /// two copies of ``ShortAuthString`` on two screens, and a connection in
    /// this mode must do nothing except pair. Reaching it for anything else is
    /// the bug.
    ///
    /// Enforced rather than asked for: ``SyncConnection`` carries this value and
    /// checks ``permits(_:)`` on every message in both directions, so the
    /// sentence above is a property of the transport rather than a note to
    /// whoever wires it next.
    case pairing
}

// MARK: - What a connection made under this policy may carry

extension PinPolicy {
    /// The messages a ``pairing`` connection is allowed to carry, in either
    /// direction, and the whole of them.
    ///
    /// Two, deliberately. First contact is one `pairRequest` and one
    /// `pairConfirm`; a set this small is one a reader can check by eye, and
    /// "does an unauthenticated peer see anything of mine" stays a question with
    /// a two-line answer.
    ///
    /// `hello` is not here even though it is a handshake message: answering one
    /// writes a protocol version into the trust store for a device nobody has
    /// approved yet. Neither is `ping`, which leaks nothing but is not pairing
    /// either — if the human staring at a ``ShortAuthString`` ever outlasts an
    /// idle timeout, adding a keepalive is a one-line change that comes with its
    /// own written reason rather than a hole that was always there.
    public static let pairingMessages: Set<SyncMessageType> = [.pairRequest, .pairConfirm]

    /// Whether a connection made under this policy may carry `type` at all.
    ///
    /// The single source of truth for the rule ``pairing`` promises, so that a
    /// caller checking it and the transport enforcing it cannot drift apart.
    /// ``pinned(_:)`` carries everything: its peer presented a certificate the
    /// user has already approved.
    public func permits(_ type: SyncMessageType) -> Bool {
        switch self {
        case .pinned: true
        case .pairing: Self.pairingMessages.contains(type)
        }
    }
}

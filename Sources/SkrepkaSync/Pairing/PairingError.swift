import Foundation

/// Why a pairing or a handshake was refused.
///
/// Every case here is fatal to the connection. There is no "log it and carry
/// on" branch, because each one describes a peer that is either not who it said
/// it was or is asking for a weaker protocol than it has already proved it can
/// speak — and both of those are the shape an attack takes.
public enum PairingError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The identity re-sent inside the tunnel names a different device than the
    /// one claimed before the handshake. Design §9's anti-downgrade rule.
    case identityChangedInsideTunnel(before: SyncDeviceID, after: SyncDeviceID)

    /// The protocol version re-sent inside the tunnel differs from the one
    /// claimed before the handshake.
    case protocolVersionChangedInsideTunnel(before: ProtocolVersion, after: ProtocolVersion)

    /// The peer advertises a lower version than the highest it has ever
    /// advertised. A genuine downgrade is a peer that was reinstalled; an
    /// attacker forcing v1 on two devices that both speak v2 looks identical,
    /// so this refuses and lets the user re-pair deliberately.
    case protocolDowngrade(offered: ProtocolVersion, remembered: ProtocolVersion)

    /// The certificate in a `pairRequest` hashes to something other than the
    /// device identifier the same message claims.
    case certificateDoesNotMatchClaim(claimed: SyncDeviceID, derived: SyncDeviceID)

    /// The certificate in a `pairRequest` is not the one the peer completed the
    /// TLS handshake with.
    ///
    /// The body of a message proves nothing; the leaf on the connection does.
    /// Under ``PinPolicy/pairing`` any well-formed leaf gets through, so a peer
    /// may present its own and carry a harvested certificate in the request —
    /// and a responder that pairs from the body shows a short authentication
    /// string for a tunnel it is not on and pins a device that never
    /// authenticated here.
    case certificateDoesNotMatchTunnel(claimed: SyncDeviceID, presented: SyncDeviceID)

    /// The peer that answered is not the peer that was dialled.
    ///
    /// ``PinPolicy/pinned(_:)`` carries the whole paired set, so a handshake
    /// with *any* already-paired device succeeds. An attacker who can spoof
    /// Bonjour redirects a connection meant for one paired device to another,
    /// and nothing in TLS notices. This is what notices.
    case reachedTheWrongPeer(expected: SyncDeviceID, reached: SyncDeviceID)

    /// A `pairRequest` whose timestamp is outside
    /// ``SyncLimits/pairingFreshnessWindow``. A replayed exchange derives a
    /// short authentication string the user has already approved once.
    case stalePairingTimestamp(pairedAt: Date, now: Date)

    /// A device tried to pair with itself, which is what a reflection attack
    /// looks like on a LAN.
    case selfPairing(deviceID: SyncDeviceID)

    /// The two ends derived different short authentication strings, which
    /// means the tunnel does not go where one of them thinks it does.
    case shortAuthenticationStringMismatch(local: String, remote: String)

    /// The peer declined.
    case rejectedByPeer

    public var description: String {
        switch self {
        case .identityChangedInsideTunnel(let before, let after):
            "peer claimed \(before) before the handshake and \(after) inside it"
        case .protocolVersionChangedInsideTunnel(let before, let after):
            "peer claimed \(before) before the handshake and \(after) inside it"
        case .protocolDowngrade(let offered, let remembered):
            "peer offered \(offered), lower than the \(remembered) it has spoken before"
        case .certificateDoesNotMatchClaim(let claimed, let derived):
            "peer claimed \(claimed) but its certificate hashes to \(derived)"
        case .certificateDoesNotMatchTunnel(let claimed, let presented):
            "peer asked to pair \(claimed) over a tunnel it opened with \(presented)"
        case .reachedTheWrongPeer(let expected, let reached):
            "dialled \(expected) and reached \(reached)"
        case .stalePairingTimestamp(let pairedAt, let now):
            "pairing timestamp \(pairedAt) is outside the freshness window at \(now)"
        case .selfPairing(let deviceID):
            "refusing to pair \(deviceID) with itself"
        case .shortAuthenticationStringMismatch(let local, let remote):
            "this device derived \(local) and the peer derived \(remote)"
        case .rejectedByPeer:
            "the peer declined the pairing"
        }
    }
}

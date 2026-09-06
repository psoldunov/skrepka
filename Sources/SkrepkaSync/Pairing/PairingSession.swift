import Foundation

/// One device's side of a first-contact pairing, and the two rules that keep a
/// paired connection from being talked back down to a weaker one.
///
/// Holds the local identity and nothing that changes, so every method is a pure
/// function of its arguments. That is deliberate: the anti-downgrade rules are
/// the part of this phase most worth testing and least worth testing through a
/// socket.
public struct PairingSession: Sendable {
    public let localIdentity: PeerIdentity
    public let localCertificate: DeviceCertificate

    public init(localIdentity: PeerIdentity, localCertificate: DeviceCertificate) {
        self.localIdentity = localIdentity
        self.localCertificate = localCertificate
    }

    // MARK: - First contact

    /// The `pairRequest` this device sends.
    public func pairRequest(at pairedAt: Date) -> SyncMessage {
        .pairRequest(
            PairRequest(
                deviceID: localCertificate.deviceID,
                deviceName: localIdentity.deviceName,
                platform: localIdentity.platform,
                certificateDER: localCertificate.certificateDER,
                pairedAt: pairedAt
            )
        )
    }

    /// Validates an incoming `pairRequest` and works out the string the two
    /// humans compare.
    ///
    /// `presentedCertificateDER` is the leaf the peer actually completed the TLS
    /// handshake with — ``SyncConnection/peerCertificateDER`` — and it is what
    /// the proposal is built from. The certificate carried in the message body
    /// is compared against it and then never used again, because the body is
    /// not authenticated: under ``PinPolicy/pairing`` the verification callback
    /// accepts any well-formed leaf, so a peer can present its own certificate
    /// and name another device's in the request. Deriving the string from the
    /// claim would put a string on screen attesting a tunnel this connection is
    /// not on, and saving the claim would pin a device that never authenticated
    /// here.
    ///
    /// The initiator binds the same way at ``SyncInitiator/pair(at:)``, off
    /// ``SyncConnection/peerCertificateDER``. Both ends have to, or the half
    /// that does not is the half an attacker dials.
    ///
    /// Does not decide whether to pair — that is the user's, and it happens
    /// after the string is on screen. This produces the record that would be
    /// saved and the string that has to match first.
    public func proposal(
        for message: SyncMessage,
        presentedCertificateDER: Data,
        now: Date
    ) throws -> PairingProposal {
        guard case .pairRequest(let request) = message else {
            throw SyncProtocolError.unexpectedMessage(expected: .pairRequest, got: message.type)
        }
        try verify(request, against: presentedCertificateDER, now: now)

        let peerPublicKey = try DeviceCertificate.publicKeyBytes(
            fromCertificateDER: presentedCertificateDER
        )
        return PairingProposal(
            peer: PairedPeer(
                certificateDER: presentedCertificateDER,
                deviceName: request.deviceName,
                platform: request.platform,
                pairedAt: request.pairedAt
            ),
            shortAuthenticationString: ShortAuthString.derive(
                publicKeys: [localCertificate.publicKeyBytes, peerPublicKey],
                pairedAt: request.pairedAt
            )
        )
    }

    /// The four things about a `pairRequest` a machine can refuse on its own,
    /// before any of it reaches a human.
    ///
    /// Ordered with the tunnel binding first: it is the only one of the four
    /// that an attacker chooses the inputs to on both sides, so it is the one
    /// worth failing before anything else is derived from those bytes.
    private func verify(
        _ request: PairRequest,
        against presentedCertificateDER: Data,
        now: Date
    ) throws {
        let presented = SyncDeviceID(certificateDER: presentedCertificateDER)
        let derived = SyncDeviceID(certificateDER: request.certificateDER)
        guard derived == presented else {
            throw PairingError.certificateDoesNotMatchTunnel(claimed: derived, presented: presented)
        }
        guard derived == request.deviceID else {
            throw PairingError.certificateDoesNotMatchClaim(claimed: request.deviceID, derived: derived)
        }
        guard presented != localCertificate.deviceID else {
            throw PairingError.selfPairing(deviceID: presented)
        }
        guard abs(now.timeIntervalSince(request.pairedAt)) <= SyncLimits.pairingFreshnessWindow else {
            throw PairingError.stalePairingTimestamp(pairedAt: request.pairedAt, now: now)
        }
    }

    /// The answer to a `pairRequest`, once the user has said yes or no.
    public func pairConfirm(_ proposal: PairingProposal, accepted: Bool) -> SyncMessage {
        .pairConfirm(
            deviceID: localCertificate.deviceID,
            accepted: accepted,
            shortAuthenticationString: proposal.shortAuthenticationString
        )
    }

    // MARK: - Anti-downgrade, design §9

    /// Compares the identity claimed before the handshake against the one
    /// re-sent inside the tunnel.
    ///
    /// The pre-TLS `hello` is unauthenticated by construction — anything on the
    /// path can rewrite it. Re-sending inside the tunnel and refusing a
    /// difference is what stops a middlebox from advertising a weaker peer than
    /// the one it is actually relaying to.
    ///
    /// Only `deviceID` and `protocolVersion` are compared. A display name that
    /// changed between the two is a user renaming their laptop, not an attack.
    public static func verifyInTunnelIdentity(before: PeerIdentity, after: PeerIdentity) throws {
        guard before.deviceID == after.deviceID else {
            throw PairingError.identityChangedInsideTunnel(before: before.deviceID, after: after.deviceID)
        }
        guard before.protocolVersion == after.protocolVersion else {
            throw PairingError.protocolVersionChangedInsideTunnel(
                before: before.protocolVersion,
                after: after.protocolVersion
            )
        }
    }

    /// Refuses a peer offering a lower version than the highest it has ever
    /// offered.
    ///
    /// `remembered` being nil is first contact, which is never a downgrade —
    /// there is nothing to be lower than.
    public static func verifyNoDowngrade(offered: ProtocolVersion, remembered: ProtocolVersion?) throws {
        guard let remembered, offered < remembered else { return }
        throw PairingError.protocolDowngrade(offered: offered, remembered: remembered)
    }
}

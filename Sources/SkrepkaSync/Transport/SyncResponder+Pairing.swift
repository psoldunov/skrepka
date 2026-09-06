import Foundation

/// First contact and the handshake, split out of ``SyncResponder`` so the file
/// that answers a peer's *questions* stays readable beside the one that decides
/// whether to trust it at all.
extension SyncResponder {
    /// Turns one `pairRequest` — and only one — into the answer the user chose.
    ///
    /// The certificate handed to ``PairingSession/proposal(for:presentedCertificateDER:now:)``
    /// is the connection's, not the request's. Under ``PinPolicy/pairing`` the
    /// verification callback accepts any well-formed leaf, so the certificate in
    /// the body is a claim and the one on the connection is the only thing the
    /// peer has proved it holds.
    func answerPairRequest(_ message: SyncMessage) async throws -> SyncMessage {
        guard proposal == nil else {
            // Closed before throwing, the way ``SyncConnection/receive()``
            // closes on a policy refusal: a throw alone leaves a peer that has
            // already misused the connection holding an open socket.
            await connection.close()
            throw SyncTransportError.repeatedPairRequest
        }
        let proposal = try session.proposal(
            for: message,
            presentedCertificateDER: connection.peerCertificateDER,
            now: now()
        )
        self.proposal = proposal
        let accepted = await confirmPairing(proposal)
        if accepted {
            try await trust.savePairedPeer(proposal.peer)
        }
        return session.pairConfirm(proposal, accepted: accepted)
    }

    func answerHello(_ message: SyncMessage) async throws -> SyncMessage {
        guard let peer = PeerIdentity(hello: message) else {
            throw SyncProtocolError.unexpectedMessage(expected: .hello, got: message.type)
        }
        guard peer.deviceID == connection.peerDeviceID else {
            throw PairingError.identityChangedInsideTunnel(
                before: connection.peerDeviceID,
                after: peer.deviceID
            )
        }
        try PairingSession.verifyNoDowngrade(
            offered: peer.protocolVersion,
            remembered: try await trust.highestProtocolVersion(for: peer.deviceID)
        )
        try await trust.recordProtocolVersion(peer.protocolVersion, for: peer.deviceID)
        // A peer may have been renamed or reinstalled onto another system since
        // it was paired, and the identity proved inside the tunnel is the one to
        // believe.
        try await trust.refreshPeerIdentity(peer)
        return session.localIdentity.hello
    }
}

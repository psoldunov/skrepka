import Foundation

/// The asking half of a connection: pairs, says hello, requests an index,
/// fetches a payload.
///
/// Split from ``SyncResponder`` because the two roles read the same stream and
/// only one of them may hold it at a time. Phase 2 makes the exchange strictly
/// turn-taking — the initiator asks, the responder answers, nobody interrupts —
/// which is why neither needs a correlation identifier on messages. Phase 3's
/// live push is what breaks that and will need one.
///
/// ``pair(at:)`` is the only method a ``PinPolicy/pairing`` connection reaches
/// the end of. The rest throw
/// ``SyncPolicyError/refusedToSendOutsidePairing(_:)`` from their first
/// ``SyncConnection/send(_:)``, before any bytes leave, so this side cannot ask
/// a peer for history it has not yet agreed to trust.
public actor SyncInitiator {
    private let connection: SyncConnection
    private let session: PairingSession
    private let trust: any TrustStore

    /// The receiver's clock, which is the only thing a peer's timestamps can be
    /// bounded against. Injected so a test can hold it still — see
    /// ``InboundClock``.
    private let now: @Sendable () -> Date

    /// Fails unless the connection reached the device the caller meant to dial.
    ///
    /// ``PinPolicy/pinned(_:)`` carries the *whole* paired set, and the
    /// verification callback asks only whether the leaf is somewhere in it. So
    /// an attacker who can spoof Bonjour — which is the assumed threat on a
    /// coffee-shop LAN — redirects a connection meant for the desktop to the
    /// laptop, and every layer below this one is satisfied: the certificate is
    /// pinned, the tunnel is real, `hello` names the device that answered. The
    /// only thing that notices is a comparison against the device that was
    /// asked for.
    ///
    /// Refused at construction rather than checked in each method, so there is
    /// no window in which an initiator pointed at the wrong peer exists.
    /// `expecting` has no default: a caller that genuinely does not know who it
    /// is about to meet — first contact, where there is nothing pinned yet —
    /// says so by passing nil, and one that does know cannot forget to say it.
    public init(
        connection: SyncConnection,
        session: PairingSession,
        trust: any TrustStore,
        expecting expectedPeerDeviceID: SyncDeviceID?,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        if let expectedPeerDeviceID, expectedPeerDeviceID != connection.peerDeviceID {
            throw PairingError.reachedTheWrongPeer(
                expected: expectedPeerDeviceID,
                reached: connection.peerDeviceID
            )
        }
        self.connection = connection
        self.session = session
        self.trust = trust
        self.now = now
    }

    // MARK: - Pairing

    /// Sends a `pairRequest` and checks the answer.
    ///
    /// The returned proposal is what the user is shown. Saving the peer is the
    /// caller's, after the two strings have been compared — this refuses only
    /// the failures a machine can see.
    public func pair(at pairedAt: Date) async throws -> PairingProposal {
        try await connection.send(session.pairRequest(at: pairedAt))
        let reply = try await expect(.pairConfirm)
        guard case .pairConfirm(let deviceID, let accepted, let remoteString) = reply else {
            throw SyncProtocolError.unexpectedMessage(expected: .pairConfirm, got: reply.type)
        }
        guard accepted else { throw PairingError.rejectedByPeer }

        // The certificate is the only authenticated claim on this connection.
        // A `pairConfirm` naming a different device is either a bug or a relay.
        guard deviceID == connection.peerDeviceID else {
            throw PairingError.identityChangedInsideTunnel(
                before: connection.peerDeviceID,
                after: deviceID
            )
        }

        let peerKey = try DeviceCertificate.publicKeyBytes(fromCertificateDER: connection.peerCertificateDER)
        let expected = ShortAuthString.derive(
            publicKeys: [session.localCertificate.publicKeyBytes, peerKey],
            pairedAt: pairedAt
        )
        guard expected == remoteString else {
            throw PairingError.shortAuthenticationStringMismatch(local: expected, remote: remoteString)
        }

        return PairingProposal(
            peer: PairedPeer(
                certificateDER: connection.peerCertificateDER,
                // The peer's own name arrives in `hello`; until then the
                // fingerprint is a name a user can at least match to a screen.
                deviceName: deviceID.fingerprint,
                platform: .unknown,
                pairedAt: pairedAt
            ),
            shortAuthenticationString: expected
        )
    }

    // MARK: - Handshake

    /// Exchanges `hello` inside the tunnel and applies design §9's two rules.
    ///
    /// The `hello` sent before a tunnel exists is unauthenticated by
    /// construction, so it is the discovery record's claim rather than the
    /// peer's. Re-sending in here and comparing against the identity the
    /// certificate proved is what makes the pre-TLS claim unable to lie about
    /// anything that matters.
    @discardableResult
    public func handshake() async throws -> PeerIdentity {
        try await connection.send(session.localIdentity.hello)
        let reply = try await expect(.hello)
        guard let peer = PeerIdentity(hello: reply) else {
            throw SyncProtocolError.unexpectedMessage(expected: .hello, got: reply.type)
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
        return peer
    }

    // MARK: - Index and payload

    /// Asks for everything created at or after `cursor`, following the peer's
    /// pages until it marks one final.
    ///
    /// Every page goes through ``InboundClock`` as it arrives, so what this
    /// returns is already bounded against *this* device's clock and the caller
    /// cannot forget to do it. A peer an hour fast otherwise wins every merge
    /// for an hour — see ``InboundClock`` for why such a row is refused rather
    /// than clamped, and ``SyncLimits/maximumClockSkew`` for the size of the
    /// window. Each page is checked at the instant it lands rather than all of
    /// them at the end, because a large index pages over a long enough stretch
    /// that one reading of the clock would be the wrong one for most of it.
    public func requestIndex(
        since cursor: Date?
    ) async throws -> (items: [SyncClipMeta], tombstones: [Tombstone]) {
        try await connection.send(.indexRequest(since: cursor))
        var items: [SyncClipMeta] = []
        var tombstones: [Tombstone] = []
        while true {
            let reply = try await expect(.indexOffer)
            guard case .indexOffer(let page, let deletions, let isFinal) = reply else {
                throw SyncProtocolError.unexpectedMessage(expected: .indexOffer, got: reply.type)
            }
            let receivedAt = now()
            items += InboundClock.plausible(page, receivedAt: receivedAt)
            tombstones += InboundClock.plausible(deletions, receivedAt: receivedAt)
            if isFinal { return (items, tombstones) }
        }
    }

    /// Fetches one representation, one ``SyncLimits/payloadChunkBytes`` slice
    /// at a time.
    ///
    /// Asks the peer that offered the representation rather than assuming the
    /// local descriptor list is complete: ``SyncClipMeta/combining(_:)``
    /// deliberately does not union representation lists, because a list is a
    /// claim about what its owner can serve.
    public func fetchPayload(contentHash: String, key: RepresentationKey) async throws -> Data {
        var bytes = Data()
        while true {
            try await connection.send(
                .payloadRequest(contentHash: contentHash, key: key, offset: Int64(bytes.count))
            )
            let reply = try await expect(.payloadChunk)
            guard case .payloadChunk(let chunk) = reply else {
                throw SyncProtocolError.unexpectedMessage(expected: .payloadChunk, got: reply.type)
            }
            guard chunk.offset == Int64(bytes.count) else {
                throw SyncProtocolError.payloadOutOfOrder(
                    expected: Int64(bytes.count),
                    got: chunk.offset
                )
            }
            bytes += chunk.bytes
            guard bytes.count <= SyncLimits.maximumPayloadBytes else {
                throw SyncProtocolError.payloadTooLarge(bytes: bytes.count)
            }
            if chunk.isFinal { return bytes }
        }
    }

    private func expect(_ type: SyncMessageType) async throws -> SyncMessage {
        guard let reply = try await connection.receive() else {
            throw SyncProtocolError.connectionClosed
        }
        guard reply.type == type else {
            throw SyncProtocolError.unexpectedMessage(expected: type, got: reply.type)
        }
        return reply
    }
}

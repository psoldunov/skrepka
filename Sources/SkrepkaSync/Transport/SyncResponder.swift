import Foundation

/// Whether the user accepted a pairing, having seen its
/// ``PairingProposal/shortAuthenticationString`` on screen.
///
/// A closure rather than a `Bool` because there is no answer a machine can give
/// here: comparing two strings on two screens is the whole man-in-the-middle
/// defence, and anything that answers this without a human has removed it.
public typealias PairingConfirmation = @Sendable (PairingProposal) async -> Bool

/// The answering half of a connection: reads a message, produces the replies,
/// repeats until the peer goes.
///
/// Keeps two pieces of per-connection state and no more: the proposal it made,
/// which is also what makes a second `pairRequest` refusable, and the set of
/// content hashes it has offered, which is what a `payloadRequest` is checked
/// against. Both are scoped to the connection, so restarting on a reconnect
/// costs nothing and grants nothing.
///
/// Has no idea what ``PinPolicy`` its connection was made under, and does not
/// need one: ``SyncConnection/receive()`` refuses anything a
/// ``PinPolicy/pairing`` connection may not carry, so the index and payload
/// branches below are unreachable there. The check sits one layer down because
/// this actor is one of several readers of the same stream — the initiator is
/// another, and Phase 3's live-push reader will be a third — and a rule written
/// into one reader is a rule the other two do not have.
public actor SyncResponder {
    /// Ceiling on ``offeredHashes``.
    ///
    /// A peer that walks the index with a fresh cursor each time must not be
    /// able to grow this set without bound — that would be a second
    /// attacker-driven buffer of exactly the kind ``Mailbox``'s ceiling exists
    /// to stop. Past the ceiling the set is replaced by the newest offer, which
    /// is the one a peer that is genuinely fetching is working from.
    private static let offeredHashLimit = 4096

    private let connection: SyncConnection
    private let session: PairingSession
    private let trust: any TrustStore
    private let store: any HistoryStoring
    private let confirmPairing: PairingConfirmation
    private let now: @Sendable () -> Date

    private var proposal: PairingProposal?

    /// Content hashes this connection has been offered, and so the only ones a
    /// `payloadRequest` on it may name.
    ///
    /// Per connection rather than global: what this device holds is not the
    /// question a peer is entitled to ask, and answering `payload(for:key:)` for
    /// any hash turns the responder into an oracle a peer can walk hash by hash
    /// — nil and non-nil answer it just as well as the bytes would.
    private var offeredHashes: Set<String> = []

    public init(
        connection: SyncConnection,
        session: PairingSession,
        trust: any TrustStore,
        store: any HistoryStoring,
        confirmPairing: @escaping PairingConfirmation,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.connection = connection
        self.session = session
        self.trust = trust
        self.store = store
        self.confirmPairing = confirmPairing
        self.now = now
    }

    /// The pairing this connection last proposed, for a caller that has to show
    /// it.
    public func lastProposal() -> PairingProposal? { proposal }

    /// Answers until the peer hangs up, or until first contact is finished.
    ///
    /// A `pairConfirm` written ends the exchange rather than continuing it.
    /// ``PinPolicy/pairingMessages`` defines first contact as one request and
    /// one confirm, and a connection left open past the confirm is one an
    /// unauthenticated peer can raise a second approval sheet on — which is the
    /// failure mode a short authentication string depends on the user *not*
    /// having, because a user worn down by prompts stops reading them.
    public func serve() async throws {
        while let message = try await connection.receive() {
            for reply in try await replies(to: message) {
                try await connection.send(reply)
                if reply.type == .pairConfirm {
                    await connection.close()
                    return
                }
            }
        }
    }

    func replies(to message: SyncMessage) async throws -> [SyncMessage] {
        switch message {
        case .pairRequest:
            [try await answerPairRequest(message)]
        case .hello:
            [try await answerHello(message)]
        case .indexRequest(let cursor):
            try await answerIndexRequest(since: cursor)
        case .payloadRequest(let contentHash, let key, let offset):
            [try await answerPayloadRequest(contentHash: contentHash, key: key, offset: offset)]
        case .indexOffer(let items, let tombstones, _):
            try await mergeOffer(items: items, tombstones: tombstones)
        case .tombstone(let tombstones):
            try await mergeOffer(items: [], tombstones: tombstones)
        case .ping(let nonce):
            [.ping(nonce: nonce)]
        case .itemMeta, .payloadChunk, .livePush, .pairConfirm:
            // Nothing this side asked for. Phase 3 gives the connection a
            // second reader and these become live-push arrivals; until then a
            // peer sending one unprompted gets silence rather than a hang-up.
            // When `itemMeta` and `livePush` do start landing, their metadata
            // goes through ``InboundClock`` the way ``mergeOffer(items:tombstones:)``
            // does — a live push carries the same sender-stamped `createdAt`
            // and pin register an index offer does.
            []
        }
    }

    /// Turns one `pairRequest` — and only one — into the answer the user chose.
    ///
    /// The certificate handed to ``PairingSession/proposal(for:presentedCertificateDER:now:)``
    /// is the connection's, not the request's. Under ``PinPolicy/pairing`` the
    /// verification callback accepts any well-formed leaf, so the certificate in
    /// the body is a claim and the one on the connection is the only thing the
    /// peer has proved it holds.
    private func answerPairRequest(_ message: SyncMessage) async throws -> SyncMessage {
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

    private func answerHello(_ message: SyncMessage) async throws -> SyncMessage {
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
        return session.localIdentity.hello
    }

    private func answerIndexRequest(since cursor: Date?) async throws -> [SyncMessage] {
        let items = try await store.syncIndex(since: cursor)
        recordOffer(items)
        return [
            .indexOffer(
                items: items,
                tombstones: try await store.tombstones(since: cursor),
                isFinal: true
            )
        ]
    }

    /// Remembers what this connection may go on to ask for the bytes of.
    private func recordOffer(_ items: [SyncClipMeta]) {
        let hashes = items.map(\.contentHash)
        if offeredHashes.count + hashes.count > Self.offeredHashLimit {
            offeredHashes = Set(hashes)
        } else {
            offeredHashes.formUnion(hashes)
        }
    }

    /// One slice, so the asking side controls the pace and can resume.
    ///
    /// A hash this connection was never offered is refused rather than answered,
    /// and the two outcomes are deliberately different. A representation this
    /// store cannot serve answers with an empty final chunk at offset zero — the
    /// peer asked whether these bytes are available here, and "no" is an
    /// ordinary answer rather than a fault, which the asking side detects by
    /// comparing what it got against the descriptor's byte count. Giving that
    /// same answer for an *unoffered* hash would let a peer walk arbitrary
    /// hashes and read this device's contents out of which ones come back
    /// non-empty, so the connection goes instead.
    private func answerPayloadRequest(
        contentHash: String,
        key: RepresentationKey,
        offset: Int64
    ) async throws -> SyncMessage {
        guard offeredHashes.contains(contentHash) else {
            await connection.close()
            throw SyncTransportError.payloadNotOffered(contentHash: contentHash)
        }
        guard
            let payload = try await store.payload(for: contentHash, key: key),
            offset >= 0, offset < Int64(payload.count)
        else {
            return .payloadChunk(
                PayloadChunk(
                    contentHash: contentHash,
                    key: key,
                    offset: offset,
                    bytes: Data(),
                    isFinal: true
                )
            )
        }

        let start = payload.startIndex + Int(offset)
        let end = min(start + SyncLimits.payloadChunkBytes, payload.endIndex)
        return .payloadChunk(
            PayloadChunk(
                contentHash: contentHash,
                key: key,
                offset: offset,
                bytes: Data(payload[start..<end]),
                isFinal: end == payload.endIndex
            )
        )
    }

    /// Folds a peer's offer into the local store and answers nothing: a merge
    /// is applied, not acknowledged, and the next index request is what shows
    /// whether it landed.
    ///
    /// The offer is filtered through ``InboundClock`` first, and this is the
    /// only layer that can do it: ``MergeEngine/plan(_:)`` is pure and its `now`
    /// is one sender-independent instant rather than a second opinion about what
    /// time it is. Anything a peer stamped further than
    /// ``SyncLimits/maximumClockSkew`` into the future is dropped rather than
    /// merged, so a machine with a wrong clock cannot outrank every local write
    /// until the skew is spent. The clock is read once and used for both, so the
    /// same instant decides what is plausible and what has expired.
    private func mergeOffer(items: [SyncClipMeta], tombstones: [Tombstone]) async throws -> [SyncMessage] {
        let receivedAt = now()
        let plan = MergeEngine.plan(
            MergeInput(
                localItems: try await store.syncIndex(since: nil),
                localTombstones: try await store.tombstones(since: nil),
                remoteItems: InboundClock.plausible(items, receivedAt: receivedAt),
                remoteTombstones: InboundClock.plausible(tombstones, receivedAt: receivedAt),
                now: receivedAt
            )
        )
        try await store.applyRemote(plan)
        return []
    }
}

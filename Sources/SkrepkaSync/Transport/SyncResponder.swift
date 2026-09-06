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
/// this actor is one of two readers of the same stream — ``SyncInitiator`` is
/// the other — and a rule written into one reader is a rule the other does not
/// have.
///
/// **Every unsolicited message a peer sends arrives here**, live push included:
/// a device only pushes over the connection it dialled, where it holds the
/// initiator's role, so the answering end of every connection is this one. See
/// ``SyncInitiator`` for why that removes the need for a correlation identifier
/// the design expected to need.
public actor SyncResponder {
    /// Ceiling on ``offeredHashes``.
    ///
    /// A peer that walks the index with a fresh cursor each time must not be
    /// able to grow this set without bound — that would be a second
    /// attacker-driven buffer of exactly the kind ``Mailbox``'s ceiling exists
    /// to stop. Past the ceiling the set is replaced by the newest offer, which
    /// is the one a peer that is genuinely fetching is working from.
    private static let offeredHashLimit = 4096

    // Internal rather than private: `SyncResponder+Pairing.swift` is the other
    // half of this actor, and Swift scopes `private` to the file it is written
    // in.
    let connection: SyncConnection
    let session: PairingSession
    let trust: any TrustStore
    let store: any HistoryStoring
    let confirmPairing: PairingConfirmation
    private let onLivePush: LivePushSink
    let now: @Sendable () -> Date

    var proposal: PairingProposal?

    /// Content hashes this connection has been offered, and so the only ones a
    /// `payloadRequest` on it may name.
    ///
    /// Per connection rather than global: what this device holds is not the
    /// question a peer is entitled to ask, and answering `payload(for:key:)` for
    /// any hash turns the responder into an oracle a peer can walk hash by hash
    /// — nil and non-nil answer it just as well as the bytes would.
    private var offeredHashes: Set<String> = []

    /// - Parameter onLivePush: told about content the peer pushed live, after
    ///   it has been stored. Defaults to doing nothing, which is what a
    ///   headless peer wants: `skrepka-sync-probe` stores a live push and has
    ///   no clipboard to put it on.
    public init(
        connection: SyncConnection,
        session: PairingSession,
        trust: any TrustStore,
        store: any HistoryStoring,
        confirmPairing: @escaping PairingConfirmation,
        onLivePush: @escaping LivePushSink = { _, _ in },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.connection = connection
        self.session = session
        self.trust = trust
        self.store = store
        self.confirmPairing = confirmPairing
        self.onLivePush = onLivePush
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

    /// One message in, whatever it is answered with out.
    ///
    /// Split in two along the line the protocol already draws: a message that
    /// asks this side for something, and a message that tells this side
    /// something. The second group answers with nothing — a merge is applied,
    /// not acknowledged — so keeping them apart is also what makes "which
    /// messages produce a frame" readable at a glance.
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
        case .ping(let nonce):
            [.ping(nonce: nonce)]
        default:
            try await absorb(message)
        }
    }

    /// The messages a peer sends to tell this side something, and the ones it
    /// has no business sending at all.
    private func absorb(_ message: SyncMessage) async throws -> [SyncMessage] {
        switch message {
        case .indexOffer(let items, let tombstones, _):
            try await mergeOffer(items: items, tombstones: tombstones)
        case .tombstone(let tombstones):
            try await mergeOffer(items: [], tombstones: tombstones)
        case .livePush(let meta, let inline):
            try await acceptLivePush(meta, inline: inline)
        default:
            // `itemMeta`, `payloadChunk` and `pairConfirm`: nothing this side
            // asked for, and nothing this build sends unprompted, so a peer
            // sending one gets silence rather than a hang-up. `itemMeta` is
            // deliberately not wired to the live-push path it resembles — no
            // sender exists for it, and a handler with no sender is an untested
            // way into the store.
            []
        }
    }

    /// Stores content a peer pushed live, then tells the sink about it.
    ///
    /// The metadata goes through ``InboundClock`` exactly as an index offer's
    /// does — a live push carries the same sender-stamped `createdAt` and pin
    /// register, and a peer whose clock is far ahead must not win every later
    /// ordering because it arrived on a different message. An implausible push
    /// is dropped whole and silently, the same answer ``mergeOffer(items:tombstones:)``
    /// gives.
    ///
    /// Stored *before* the sink runs, and the sink's outcome is not consulted:
    /// putting this on the clipboard is a convenience, keeping it in history is
    /// the product. A sink that throws or hangs must not cost the row.
    ///
    /// Answers with no messages. A live push is applied, not acknowledged — see
    /// ``SyncInitiator/push(_:payloads:)``.
    private func acceptLivePush(
        _ meta: SyncClipMeta,
        inline: [RepresentationKey: Data]
    ) async throws -> [SyncMessage] {
        guard InboundClock.isPlausible(meta, receivedAt: now()) else { return [] }
        try await store.capture(meta, payloads: inline)
        await onLivePush(meta, inline)
        return []
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

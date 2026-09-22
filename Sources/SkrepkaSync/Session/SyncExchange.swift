import Foundation

/// One index exchange with one peer: ask, merge, apply, fetch what is missing.
///
/// A type of its own rather than three methods on ``PeerLink``, because it is
/// the part with rules in it and the link is the part with a socket in it.
/// Everything here is derived from two indexes and a plan, so a reader checking
/// "can this resurrect something the user deleted" has one file to read.
public struct SyncExchange: Sendable {
    public let runtime: SyncRuntime
    public let initiator: SyncInitiator
    /// An item to fetch before any other, whatever its age — the one a peer
    /// just pushed without its bytes. See ``PeerLink/fetchPushed(_:)``.
    public let priority: String?
    /// Told about every item whose bytes this exchange fetched and stored,
    /// with the bytes it fetched.
    private let onFetched: LivePushSink
    /// Bytes this exchange may fetch — ``PeerLink/payloadBudgetPerSync``
    /// outside a test.
    let budget: Int

    public init(
        runtime: SyncRuntime,
        initiator: SyncInitiator,
        priority: String? = nil,
        onFetched: @escaping LivePushSink = { _, _ in }
    ) {
        self.init(
            runtime: runtime,
            initiator: initiator,
            priority: priority,
            budget: PeerLink.payloadBudgetPerSync,
            onFetched: onFetched
        )
    }

    init(
        runtime: SyncRuntime,
        initiator: SyncInitiator,
        priority: String?,
        budget: Int,
        onFetched: @escaping LivePushSink
    ) {
        self.runtime = runtime
        self.initiator = initiator
        self.priority = priority
        self.budget = budget
        self.onFetched = onFetched
    }

    /// Runs the exchange and answers how many items this device did not have
    /// before.
    ///
    /// **The whole index, every time, rather than a cursor.** A cursor would
    /// save the peer describing items this device already has, and it would buy
    /// that with a rule about which of `createdAt` and `deletedAt` it advances
    /// against and what happens to the items an interrupted round never reached.
    /// The local half of the merge reads the full local index regardless —
    /// `MergeEngine` needs all of it — so the saving is one direction of a few
    /// hundred bytes per item, once every ``PeerLink/resyncInterval``. Re-asking
    /// is also what makes the payload fetch self-healing: an item the budget
    /// skipped is offered again next round and picked up then.
    public func run() async throws -> Int {
        let offer = try await initiator.requestIndex(since: nil)
        // Read after the offer arrives rather than before it: the exchange takes
        // real time, and anything captured locally during it belongs in the
        // merge's picture of what this device holds.
        let receivedAt = Date()
        let localItems = try await runtime.store.syncIndex(since: nil)
        let plan = MergeEngine.plan(
            MergeInput(
                localItems: localItems,
                localTombstones: try await runtime.store.tombstones(since: nil),
                remoteItems: offer.items,
                remoteTombstones: offer.tombstones,
                now: receivedAt
            )
        )
        try await runtime.store.applyRemote(plan)
        try await fetchPayloads(offered: offer.items, holding: localItems, after: plan)
        return plan.count { action in
            if case .insert = action { return true }
            return false
        }
    }

    // MARK: - Payloads

    /// Fetches the bytes of everything this device now holds and cannot serve.
    ///
    /// **Only for content the store holds after the merge**, and that
    /// restriction is the whole point rather than an optimisation. A peer offers
    /// its live index and its tombstones together, and a tombstone can cover an
    /// item in that same index — the merge resolves it to
    /// ``MergeAction/deleteLocally(contentHash:)``, or to no action at all where
    /// this device never had the row. Fetching from the offer alone and calling
    /// ``HistoryStoring/capture(_:payloads:)`` would then write the row straight
    /// back, and "deleted, re-synced, still deleted" would be false.
    ///
    /// One `capture` per item with every missing representation at once, never
    /// one per representation: a store fills a learned row's payload while it is
    /// empty and leaves a non-empty one alone — it has to, or a peer could
    /// overwrite bytes this device captured itself — so a second call for the
    /// same row would be dropped.
    ///
    /// Bytes that show the item to be a Universal Clipboard relay are not
    /// stored: the row the merge just learned is discarded and tombstoned
    /// instead — see ``UniversalClipboardRelay``.
    ///
    /// A bundle over this device's file-size limit is never fetched — see
    /// ``FileSyncLimit``. The row still arrives, and pastes as the files'
    /// names, which is what the limit promises.
    private func fetchPayloads(
        offered: [SyncClipMeta],
        holding localItems: [SyncClipMeta],
        after plan: [MergeAction]
    ) async throws {
        let servable = Self.servableRepresentations(localItems)
        let held = Self.contentHeld(afterApplying: plan, to: Set(servable.keys))
        let fileLimit = await runtime.fileSync.maximumBytes
        var budget = self.budget

        // Newest first: what the user is about to reach for is what they copied
        // most recently, and a budget that runs out should run out on the oldest
        // items rather than on the ones on screen. A pushed item waiting for
        // its bytes goes ahead of all of them.
        for meta in fetchOrder(offered) {
            guard budget > 0 else { return }
            guard held.contains(meta.contentHash) else { continue }
            let missing = meta.representations.filter {
                !(servable[meta.contentHash] ?? []).contains($0.key)
                    && FileSyncLimit.admits($0, under: fileLimit)
            }
            guard !missing.isEmpty else { continue }
            // Ended however the fetch ends, and only once the bytes are stored,
            // so a row's bar gives way to the finished row rather than to
            // "not synced yet" for the moment in between.
            do {
                try await fetchAndStore(missing, of: meta, fileLimit: fileLimit, budget: &budget)
            } catch {
                await runtime.transfers.end(meta.contentHash)
                throw error
            }
            await runtime.transfers.end(meta.contentHash)
        }
    }

    private func fetchAndStore(
        _ missing: [RepresentationDescriptor],
        of meta: SyncClipMeta,
        fileLimit: Int,
        budget: inout Int
    ) async throws {
        let fetched = try await fetch(missing, of: meta, fileLimit: fileLimit, budget: &budget)
        guard !fetched.isEmpty else { return }
        // The bytes are the first point at which a relay can be told from a
        // file: an index entry names its files by display name alone.
        if UniversalClipboardRelay.isRelay(meta, payloads: fetched) {
            try await runtime.store.discardRelay(meta, by: runtime.deviceID, at: Date())
            return
        }
        try await runtime.store.capture(meta, payloads: fetched)
        await onFetched(meta, fetched)
    }

    private func fetchOrder(_ offered: [SyncClipMeta]) -> [SyncClipMeta] {
        offered.sorted { lhs, rhs in
            let lhsFirst = lhs.contentHash == priority
            let rhsFirst = rhs.contentHash == priority
            guard lhsFirst == rhsFirst else { return lhsFirst }
            return lhs.createdAt > rhs.createdAt
        }
    }

    /// The bytes of one item's missing representations, spending from `budget`.
    ///
    /// A representation is fetched only if its offered size fits what is left,
    /// and the fetch itself is capped there, so a peer that understated a size
    /// cannot spend more than the budget either. What does not fit is left for
    /// a later round, which re-offers it — two 20 MB pictures are one round's
    /// work each, not 40 MB of one.
    ///
    /// Reports to ``SyncRuntime/transfers`` as it goes: the offered sizes of
    /// what fits are the total, and every chunk moves the count on. The caller
    /// ends the transfer, once the bytes are stored.
    private func fetch(
        _ missing: [RepresentationDescriptor],
        of meta: SyncClipMeta,
        fileLimit: Int,
        budget: inout Int
    ) async throws -> [RepresentationKey: Data] {
        let transfers = runtime.transfers
        let contentHash = meta.contentHash
        await transfers.begin(contentHash, totalBytes: Self.plannedBytes(missing, budget: budget))
        var fetched: [RepresentationKey: Data] = [:]
        var received = 0
        for descriptor in missing {
            guard descriptor.byteCount >= 0, descriptor.byteCount <= budget else { continue }
            let before = received
            let bytes = try await initiator.fetchPayload(
                contentHash: contentHash,
                key: descriptor.key,
                atMost: FileSyncLimit.fetchCap(for: descriptor.key, budget: budget, limit: fileLimit)
            ) { count in
                await transfers.advance(contentHash, to: before + count)
            }
            // An empty final chunk at offset zero is how a peer says it cannot
            // serve those bytes after all — evicted since it offered them, or
            // never held them. An ordinary answer, not a fault.
            guard !bytes.isEmpty else { continue }
            fetched[descriptor.key] = bytes
            budget -= bytes.count
            received += bytes.count
            await transfers.advance(contentHash, to: received)
        }
        return fetched
    }

    /// The offered bytes of every descriptor ``fetch(_:of:budget:)`` will ask
    /// for, taking them in its order and spending `budget` as it would.
    static func plannedBytes(_ missing: [RepresentationDescriptor], budget: Int) -> Int {
        var remaining = budget
        var planned = 0
        for descriptor in missing where descriptor.byteCount >= 0 && descriptor.byteCount <= remaining {
            remaining -= descriptor.byteCount
            planned += descriptor.byteCount
        }
        return planned
    }

    /// What each locally held item can already serve, so nothing is fetched
    /// twice.
    private static func servableRepresentations(
        _ items: [SyncClipMeta]
    ) -> [String: Set<RepresentationKey>] {
        var servable: [String: Set<RepresentationKey>] = [:]
        for item in items {
            servable[item.contentHash] = Set(item.representations.map(\.key))
        }
        return servable
    }

    /// The content this device holds once `plan` has been applied.
    ///
    /// **What the store will accept, not what the plan asked for**, which is the
    /// distinction a concealed item turns into a permanent cost. `applyRemote`
    /// drops an `.insert` whose metadata is concealed on both engines, so
    /// crediting one here has this exchange fetch a full payload for a row that
    /// does not exist, and `capture` refuse the bytes on arrival — every round,
    /// for as long as the peer keeps offering it, out of a budget that would
    /// otherwise have gone to items the user can see. A well-behaved peer never
    /// offers concealed content, because `syncIndex` filters it; a paired peer is
    /// authenticated rather than trusted to be well-behaved.
    ///
    /// **Stale by the time it is used, and knowingly so.** It is computed from
    /// one plan and then consulted across a fetch that can run for minutes, while
    /// neither engine's `capture` consults the tombstone table. So a clip deleted
    /// locally — in the picker, or by another peer's tombstone — while its bytes
    /// are in flight is written back by `capture` and sits beside its own
    /// tombstone until the next merge removes it again, within
    /// ``PeerLink/resyncInterval``. Left as it is: closing it means `capture`
    /// reading tombstones on every insert, which is the hot path for ordinary
    /// local copies as well, and the cost of the race is one row visible for one
    /// round.
    private static func contentHeld(
        afterApplying plan: [MergeAction],
        to local: Set<String>
    ) -> Set<String> {
        var held = local
        for action in plan {
            switch action {
            case .insert(let meta):
                guard !meta.isConcealed else { break }
                held.insert(meta.contentHash)
            case .deleteLocally(let contentHash): held.remove(contentHash)
            case .bumpCreatedAt, .applyPin, .recordTombstone, .dropTombstone: break
            }
        }
        return held
    }
}

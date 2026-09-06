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

    public init(runtime: SyncRuntime, initiator: SyncInitiator) {
        self.runtime = runtime
        self.initiator = initiator
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
    private func fetchPayloads(
        offered: [SyncClipMeta],
        holding localItems: [SyncClipMeta],
        after plan: [MergeAction]
    ) async throws {
        let servable = Self.servableRepresentations(localItems)
        let held = Self.contentHeld(afterApplying: plan, to: Set(servable.keys))
        var budget = PeerLink.payloadBudgetPerSync

        // Newest first: what the user is about to reach for is what they copied
        // most recently, and a budget that runs out should run out on the oldest
        // items rather than on the ones on screen.
        for meta in offered.sorted(by: { $0.createdAt > $1.createdAt }) {
            guard budget > 0 else { return }
            guard held.contains(meta.contentHash) else { continue }
            let missing = meta.representations.filter {
                !(servable[meta.contentHash] ?? []).contains($0.key)
            }
            guard !missing.isEmpty else { continue }
            let fetched = try await fetch(missing, of: meta, budget: &budget)
            guard !fetched.isEmpty else { continue }
            try await runtime.store.capture(meta, payloads: fetched)
        }
    }

    /// The bytes of one item's missing representations, spending from `budget`.
    private func fetch(
        _ missing: [RepresentationDescriptor],
        of meta: SyncClipMeta,
        budget: inout Int
    ) async throws -> [RepresentationKey: Data] {
        var fetched: [RepresentationKey: Data] = [:]
        for descriptor in missing {
            guard budget > 0 else { break }
            let bytes = try await initiator.fetchPayload(
                contentHash: meta.contentHash,
                key: descriptor.key
            )
            // An empty final chunk at offset zero is how a peer says it cannot
            // serve those bytes after all — evicted since it offered them, or
            // never held them. An ordinary answer, not a fault.
            guard !bytes.isEmpty else { continue }
            fetched[descriptor.key] = bytes
            budget -= bytes.count
        }
        return fetched
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
    private static func contentHeld(
        afterApplying plan: [MergeAction],
        to local: Set<String>
    ) -> Set<String> {
        var held = local
        for action in plan {
            switch action {
            case .insert(let meta): held.insert(meta.contentHash)
            case .deleteLocally(let contentHash): held.remove(contentHash)
            case .bumpCreatedAt, .applyPin, .recordTombstone, .dropTombstone: break
            }
        }
        return held
    }
}

import Foundation

@testable import SkrepkaSync

/// A store, reduced to what a merge can change about it.
///
/// The engine emits a plan rather than performing one, so a convergence test
/// needs something to apply the plan to. This is that something and nothing
/// more: no retention, no clock, no identity of its own.
struct MergeReplica: Equatable {
    private(set) var items: [String: SyncClipMeta] = [:]
    private(set) var tombstones: [String: Tombstone] = [:]

    init(items: [SyncClipMeta] = [], tombstones: [Tombstone] = []) {
        for item in items { self.items[item.contentHash] = item }
        for tombstone in tombstones { self.tombstones[tombstone.contentHash] = tombstone }
    }

    mutating func apply(_ actions: [MergeAction]) {
        for action in actions {
            switch action {
            case .insert(let meta):
                items[meta.contentHash] = meta
            case .bumpCreatedAt(let contentHash, let createdAt):
                items[contentHash] = items[contentHash].map { Self.copy($0, createdAt: createdAt) }
            case .applyPin(let contentHash, let register):
                items[contentHash] = items[contentHash].map { Self.copy($0, isPinned: register) }
            case .deleteLocally(let contentHash):
                items[contentHash] = nil
            case .recordTombstone(let tombstone):
                tombstones[tombstone.contentHash] = tombstone
            case .dropTombstone(let contentHash):
                tombstones[contentHash] = nil
            }
        }
    }

    /// One held item with a field replaced.
    ///
    /// ``SyncClipMeta`` is a value type with `let` properties and no `with`
    /// helper, so both mutating actions have to restate the whole initializer.
    /// Once, here, rather than once per action.
    private static func copy(
        _ held: SyncClipMeta,
        createdAt: Date? = nil,
        isPinned: LWWRegister<Bool>? = nil
    ) -> SyncClipMeta {
        SyncClipMeta(
            contentHash: held.contentHash,
            kind: held.kind,
            preview: held.preview,
            createdAt: createdAt ?? held.createdAt,
            isPinned: isPinned ?? held.isPinned,
            isConcealed: held.isConcealed,
            imageWidth: held.imageWidth,
            imageHeight: held.imageHeight,
            sourceBundleID: held.sourceBundleID,
            originDeviceID: held.originDeviceID,
            representations: held.representations
        )
    }

    /// Merges a peer's whole state into this one.
    ///
    /// - Returns: whether the plan had anything in it. Gossip runs until a whole
    ///   round of merges answers `false`, and `MergeEngine` emits an action only
    ///   when it changes the receiver — an insert only for content absent here, a
    ///   bump only for a strictly later `createdAt`, a pin only when the merged
    ///   register differs — so an empty plan and an unchanged replica are the same
    ///   statement and quiescence is reached rather than merely counted to.
    @discardableResult
    mutating func merge(_ peer: MergeReplica, now: Date) -> Bool {
        let plan = MergeEngine.plan(
            MergeInput(
                localItems: Array(items.values),
                localTombstones: Array(tombstones.values),
                remoteItems: Array(peer.items.values),
                remoteTombstones: Array(peer.tombstones.values),
                now: now
            )
        )
        apply(plan)
        return !plan.isEmpty
    }
}

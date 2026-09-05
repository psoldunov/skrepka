import Foundation

/// What a merge concluded the local store should do.
///
/// A description rather than an instruction to a database: ``MergeEngine`` is
/// pure, so the plan can be inspected, compared and tested without a store
/// existing.
///
/// There is deliberately no `fetchPayload` case. Payload transfer is lazy and
/// demand-driven per design §7, so it is the transport's business — putting it
/// here would make a pure function decide when to spend bandwidth.
public enum MergeAction: Sendable, Hashable {
    /// Content the local store does not have. Emitted whether the item is new
    /// or was evicted here earlier; see ``MergeEngine`` on why those are the
    /// same case.
    ///
    /// The meta carries the offering peer's ``SyncClipMeta/representations``
    /// verbatim, and that is deliberate rather than an oversight of the rule
    /// ``SyncClipMeta/combining(_:)`` follows: a receiver with no list has
    /// nothing to ask for, so stripping it would make every learned row a
    /// permanent ghost. The list is therefore **what the origin can serve, not
    /// what this device can** — a distinction the receiving store owes the
    /// protocol, by not echoing descriptors whose bytes it has never fetched in
    /// its own `syncIndex`. Adopting the claim *and* re-advertising it is what
    /// leaves a peer requesting bytes nobody holds.
    case insert(SyncClipMeta)
    /// A repeat copy on a peer moved the item up. `to` is always later than
    /// what the local store holds.
    case bumpCreatedAt(contentHash: String, to: Date)
    /// The merged pin register differs from the local one.
    case applyPin(contentHash: String, register: LWWRegister<Bool>)
    /// A live tombstone covers content the local store still holds.
    case deleteLocally(contentHash: String)
    /// A deletion the local store has not recorded, or has recorded
    /// differently.
    case recordTombstone(Tombstone)
    /// A tombstone the local store holds whose retention window has passed.
    ///
    /// Leaving expired records out of the plan bounds what a merge *honours*;
    /// it does not bound what the store *keeps*. Nothing else revisits the
    /// graveyard on a machine that only ever receives — the deletion paths that
    /// prune are the ones it never takes — so without this case the rows
    /// outlive every rule that mentions them and each merge reads them back
    /// only to discard them again.
    case dropTombstone(contentHash: String)
}

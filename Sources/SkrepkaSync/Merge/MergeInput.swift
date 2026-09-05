import Foundation

/// Everything ``MergeEngine/plan(_:)`` is allowed to know.
///
/// The clock is a field rather than a call, for the same reason
/// `RetentionPolicy.idsToEvict(from:now:)` takes one: tombstone expiry is the
/// only time-dependent rule in the model, and a test that cannot choose "now"
/// cannot test a ninety-day window without waiting ninety days.
public struct MergeInput: Sendable, Hashable {
    /// What the local store holds, in any order.
    public let localItems: [SyncClipMeta]
    /// Deletions the local store has recorded, in any order.
    public let localTombstones: [Tombstone]
    /// What the peer offered.
    public let remoteItems: [SyncClipMeta]
    /// Deletions the peer offered.
    public let remoteTombstones: [Tombstone]
    /// The instant tombstone expiry is measured against.
    public let now: Date

    public init(
        localItems: [SyncClipMeta],
        localTombstones: [Tombstone] = [],
        remoteItems: [SyncClipMeta],
        remoteTombstones: [Tombstone] = [],
        now: Date = Date()
    ) {
        self.localItems = localItems
        self.localTombstones = localTombstones
        self.remoteItems = remoteItems
        self.remoteTombstones = remoteTombstones
        self.now = now
    }
}

import Foundation

/// One item whose bytes are on their way here from a peer: what a picker row
/// draws a progress bar from while it waits.
///
/// Per item rather than per representation. A file row fetches its bundle and
/// the few small forms beside it one after another, and the person looking at
/// the row is waiting for all of them — so ``totalBytes`` is the sum of what the
/// fetch set out to bring, and ``receivedBytes`` counts across all of it.
public struct PayloadTransfer: Sendable, Hashable {
    /// The item, as the history names it on both platforms.
    public let contentHash: String
    /// Bytes stored so far, across every representation of the item.
    public let receivedBytes: Int
    /// Bytes the fetch set out to bring: the offered sizes of every
    /// representation it asked for.
    public let totalBytes: Int

    public init(contentHash: String, receivedBytes: Int, totalBytes: Int) {
        self.contentHash = contentHash
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
    }

    /// How far along, from 0 to 1.
    ///
    /// Clamped at 1 because a peer can understate a size — ``SyncExchange``
    /// caps what it will read, not what the peer claimed — and a bar past its
    /// end is a worse answer than a full one.
    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(Double(receivedBytes) / Double(totalBytes), 1)
    }
}

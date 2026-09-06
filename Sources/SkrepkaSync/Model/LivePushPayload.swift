import Foundation

/// Decides what bytes travel with a `livePush` and what the peer has to come
/// back for.
///
/// Design §11's size discipline: "inline the bytes for payloads under 256 KB;
/// above that push metadata and let the peer fetch lazily, so a 20 MB
/// screenshot never blocks the live channel."
public enum LivePushPayload {
    /// The representations small enough to ride along, or nothing.
    ///
    /// **All or nothing, measured over the total.** Inlining the small
    /// representations of a large item and dropping the big one would arrive as
    /// a live push the receiver can write to the clipboard *badly* — plain text
    /// present, the PNG the user actually copied missing — and nothing in the
    /// message distinguishes that from an item whose sender only ever had the
    /// text. A receiver that gets no bytes at all knows exactly what to do,
    /// because ``SyncClipMeta/representations`` tells it what to fetch.
    ///
    /// The total is what is compared, not the largest one: the frame is what
    /// the limit protects, and a frame carries the sum.
    public static func inline(
        _ payloads: [RepresentationKey: Data]
    ) -> [RepresentationKey: Data] {
        let total = payloads.values.reduce(0) { $0 + $1.count }
        return total <= SyncLimits.livePushInlineLimit ? payloads : [:]
    }
}

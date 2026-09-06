import Foundation

/// Told about content a peer pushed live, once it has been stored.
///
/// A closure rather than a protocol requirement on ``HistoryStoring`` because
/// storing and *presenting* are different jobs on different sides of the
/// portability line. `SkrepkaSync` builds on Linux and must not know what a
/// pasteboard is; the app target hands one of these in and does the pause →
/// write → resume dance behind it. The Linux daemon will hand in its own, and a
/// headless peer — `skrepka-sync-probe` — hands in nothing at all, which is the
/// point of it.
///
/// Called **after** the item has been stored, so a sink that fails, hangs or is
/// absent cannot cost the user the history row. It receives the metadata the
/// merge accepted and whatever bytes arrived inline, which is empty for an item
/// over ``SyncLimits/livePushInlineLimit`` — see ``LivePushPayload``. A sink
/// that needs those bytes fetches them itself; this target will not spend a
/// round trip on a peer's behalf.
public typealias LivePushSink = @Sendable (SyncClipMeta, [RepresentationKey: Data]) async -> Void

import Foundation

/// Told that a peer pushed something live whose bytes did not come with it.
///
/// Above ``SyncLimits/livePushInlineLimit`` a push carries metadata alone —
/// see ``LivePushPayload`` — and without this the bytes arrived only on the next
/// index exchange, up to ``PeerLink/resyncInterval`` later: a screenshot copied
/// on one machine was not pasteable on the other for half a minute.
///
/// The responder that received the push cannot fetch anything itself: it holds
/// the answering role on its connection, and only an initiator may ask. So it
/// names the peer, and the owner of that peer's ``PeerLink`` — the coordinator
/// on each platform — hands the item to ``PeerLink/fetchPushed(_:)``.
///
/// The first argument is the device that sent the push, which is not
/// necessarily ``SyncClipMeta/originDeviceID``: a device pushes what was just
/// copied on it, and that can be content another device first recorded.
public typealias PushFetchRequest = @Sendable (SyncDeviceID, SyncClipMeta) async -> Void

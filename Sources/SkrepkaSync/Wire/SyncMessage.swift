import Foundation

/// Everything the protocol can say, per design §7's message table.
///
/// One enum rather than eleven payload structs: the set is closed, a `switch`
/// over it is exhaustive, and adding a case makes the encoder, the decoder and
/// every handler fail to compile until they are updated — which is the point.
public enum SyncMessage: Sendable, Hashable {
    /// Opens a connection. Re-sent *inside* the tunnel after the handshake, per
    /// design §9's anti-downgrade rule, so the pre-TLS and post-TLS identities
    /// can be compared.
    case hello(PeerIdentity)

    /// First contact. Carries the certificate so the far end can derive the
    /// same ``SyncDeviceID`` and check it against the one claimed.
    case pairRequest(PairRequest)

    /// The answer to a ``pairRequest``. `shortAuthenticationString` is the eight
    /// hex characters both devices display; a mismatch is the user's cue that
    /// something is in the middle.
    case pairConfirm(
        deviceID: SyncDeviceID,
        accepted: Bool,
        shortAuthenticationString: String
    )

    /// Metadata for a batch of items, with no payload bytes. `isFinal` is false
    /// while more batches follow, so a large index can be paged.
    case indexOffer(items: [SyncClipMeta], tombstones: [Tombstone], isFinal: Bool)

    /// Ask for everything created since a cursor, or everything when `since` is
    /// nil.
    case indexRequest(since: Date?)

    /// One item's metadata, out of band from an index.
    case itemMeta(SyncClipMeta)

    /// Ask for one representation's bytes, resuming at `offset`.
    case payloadRequest(contentHash: String, key: RepresentationKey, offset: Int64)

    /// A slice of a representation. ``PayloadChunk/isFinal`` marks the last
    /// one, so a receiver does not have to know the total length in advance.
    case payloadChunk(PayloadChunk)

    /// Deletion records. Batched because `clear(keepingPinned:)` emits many at
    /// once.
    case tombstone([Tombstone])

    /// Live clipboard handoff. `inline` carries the bytes for payloads under
    /// ``SyncLimits/livePushInlineLimit`` and is empty above it, where the peer
    /// fetches lazily instead so a 20 MB screenshot never blocks the channel.
    case livePush(meta: SyncClipMeta, inline: [RepresentationKey: Data])

    /// Liveness. The nonce is echoed so a reply can be matched to its request.
    case ping(nonce: Int64)

    public var type: SyncMessageType {
        switch self {
        case .hello: .hello
        case .pairRequest: .pairRequest
        case .pairConfirm: .pairConfirm
        case .indexOffer: .indexOffer
        case .indexRequest: .indexRequest
        case .itemMeta: .itemMeta
        case .payloadRequest: .payloadRequest
        case .payloadChunk: .payloadChunk
        case .tombstone: .tombstone
        case .livePush: .livePush
        case .ping: .ping
        }
    }
}

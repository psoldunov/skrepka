import Foundation

/// ``SyncMessage`` to ``CBORValue``.
///
/// Split from the decoder so neither file has to be read to understand the
/// other, and so the pair stays inside the file-length rule as the message set
/// grows.
enum SyncMessageEncoding {
    // The switch is an exhaustive table over a closed message set, so its arm
    // count is the size of the protocol rather than accidental branching.
    // Splitting it to fit the ceiling would need a `default:`, which is exactly
    // the compile-time exhaustiveness ``SyncMessage``'s doc comment says the
    // enum exists to buy — and it would scatter the wire schema this file is
    // meant to state in one place, next to the decoder that has to mirror it.
    // swiftlint:disable:next cyclomatic_complexity
    static func value(for message: SyncMessage) -> CBORValue {
        switch message {
        case .hello(let identity):
            return SyncModelCoding.value(identity)

        case .pairRequest(let request):
            return SyncModelCoding.value(request)

        case .pairConfirm(let deviceID, let accepted, let shortAuthenticationString):
            return .map(fields: [
                "deviceID": SyncModelCoding.value(deviceID),
                "accepted": .boolean(accepted),
                "shortAuthenticationString": .text(shortAuthenticationString),
            ])

        case .indexOffer(let items, let tombstones, let isFinal):
            return .map(fields: [
                "items": .array(items.map(SyncModelCoding.value)),
                "tombstones": .array(tombstones.map(SyncModelCoding.value)),
                "isFinal": .boolean(isFinal),
            ])

        case .indexRequest(let since):
            return .map(fields: ["since": .optional(since.map { .integer(WireTimestamp($0).milliseconds) })])

        case .itemMeta(let meta):
            return .map(fields: ["meta": SyncModelCoding.value(meta)])

        case .payloadRequest(let contentHash, let key, let offset):
            return .map(fields: [
                "contentHash": .text(contentHash),
                "key": SyncModelCoding.value(key),
                "offset": .integer(offset),
            ])

        case .payloadChunk(let chunk):
            return SyncModelCoding.value(chunk)

        case .tombstone(let tombstones):
            return .map(fields: ["tombstones": .array(tombstones.map(SyncModelCoding.value))])

        case .livePush(let meta, let inline):
            return .map(fields: [
                "meta": SyncModelCoding.value(meta),
                "inline": .array(inlineRepresentations(inline)),
            ])

        case .ping(let nonce):
            return .map(fields: ["nonce": .integer(nonce)])
        }
    }

    /// Inline payloads as an array of `{key, bytes}`, sorted by key.
    ///
    /// A CBOR map keyed by the representation itself would encode the same
    /// information, but sorting an array of small maps is easier to read from
    /// JavaScript than a map whose keys are themselves maps.
    private static func inlineRepresentations(_ inline: [RepresentationKey: Data]) -> [CBORValue] {
        inline.sorted { $0.key < $1.key }.map { entry in
            .map(fields: [
                "key": SyncModelCoding.value(entry.key),
                "bytes": .bytes(entry.value),
            ])
        }
    }
}

import Foundation

/// Which representations a clip carries and how many bytes each one is —
/// denormalised out of the payload so a row can be described without measuring it.
///
/// It exists for ``HistoryStore/syncIndex(since:)``, which has to report exactly
/// this. The only other place the *sizes* live is inside `ClipRecord.payloadData`,
/// which is `@Attribute(.externalStorage)`: measuring a 500-item offer from there
/// would mean 500 external reads and 500 property-list decodes to produce a few
/// kilobytes of metadata.
///
/// It is not, on its own, what an offer may advertise. A row learned from a peer
/// carries that peer's claim here beside a payload it has never fetched, so the
/// offer is the stored index narrowed to what this device holds — see
/// ``servable(_:holding:)``, which is what reintroduces a payload read on the rows
/// that have one.
///
/// Keys are the *platform's own* representation names — macOS pasteboard type
/// raw values — not the canonical media types the wire carries. Mapping to the
/// wire vocabulary is ``SyncMetaMapping``'s job, and it needs the origin key to
/// keep a Mac↔Mac round trip lossless. See `RepresentationKey.origin`.
///
/// Binary property list, matching ``ClipRecordMapping``: the index is written in
/// the same transaction as the payload it describes, and two encodings for two
/// halves of one row is a difference with no reason behind it.
enum RepresentationIndex {
    private static let encoder: PropertyListEncoder = {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }()

    /// Byte count per representation, keyed by pasteboard type raw value.
    static func make(from payload: ClipPayload) -> [String: Int] {
        payload.representations.mapValues(\.count)
    }

    /// The part of a stored index this device can actually serve.
    ///
    /// A stored index answers two different questions and they stop agreeing the
    /// moment a row is learned from a peer. `SyncMetaMapping.makeRecord` writes the
    /// *peer's* claim into it beside an empty `payloadData`, deliberately: an empty
    /// index would leave the transport with nothing to request and the row would
    /// sync as a permanent ghost. But `SyncClipMeta.representations` is a claim
    /// about what its owner can serve, so offering that same list back would
    /// promise bytes this machine has never held — a peer fetches one of two
    /// representations and then advertises both.
    ///
    /// So: the stored index is what there is to *fetch*, and this is what there is
    /// to *offer*. The payload is the only honest answer to the second, because it
    /// is what ``HistoryStore/payload(for:key:)`` reads to serve a fetch.
    ///
    /// Byte counts come from the stored index rather than from the payload. They
    /// agree wherever a representation is held — `fillPayload(of:with:)` measures
    /// what arrived rather than trusting the offer — and taking them from the index
    /// keeps this a filter rather than a second measurement to keep in step.
    ///
    /// The cost is that describing a row that holds bytes now decodes its payload
    /// after all, which is the read this type exists to avoid. It is bounded:
    /// `payloadData` stays inline until it is large, and `syncIndex(since:)` is
    /// cursor-driven once the first full offer is behind it, so the steady state
    /// touches only what was just captured. Restoring the read-free offer means
    /// recording held-ness where the index is *written*, in `SyncMetaMapping` and
    /// `HistoryStore+Storing` — the Linux engine already has it, as a `NULL`
    /// `clip_representation.bytes` beside a non-null `byte_count`.
    static func servable(_ index: [String: Int], holding payload: ClipPayload) -> [String: Int] {
        index.filter { type, _ in payload.data(forType: type) != nil }
    }

    static func encode(_ index: [String: Int]) throws -> Data {
        try encoder.encode(index)
    }

    /// Empty data decodes to an empty index rather than throwing — a row with no
    /// representations is a legitimate shape, not a corrupt one.
    static func decode(_ data: Data) throws -> [String: Int] {
        guard !data.isEmpty else { return [:] }
        return try PropertyListDecoder().decode([String: Int].self, from: data)
    }
}

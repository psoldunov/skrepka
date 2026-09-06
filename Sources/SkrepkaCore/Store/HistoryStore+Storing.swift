// The SwiftData store's conformance to `SkrepkaSync.HistoryStoring`, in a file of
// its own so nothing already written for macOS had to move for it. Linux gets a
// separate SQLite conformance in `Store/SQLite/` (D-3, D-9).
#if canImport(SwiftData)

    import Foundation
    import SkrepkaSync
    import SwiftData
    import os

    /// `HistoryStore` as a sync peer sees it.
    ///
    /// Four of the six requirements are already public API of the store and are
    /// witnessed as they stand — an actor-isolated synchronous method satisfies an
    /// `async` requirement, so the `@MainActor` hop happens at the call site. The
    /// two written here are the ones only a transport asks for: one representation
    /// out, and one item in from a peer.
    ///
    /// `nonisolated` on the conformance rather than the inferred main-actor one:
    /// `HistoryStoring` refines `Sendable`, and an isolated conformance cannot
    /// satisfy that. The witnesses stay main-actor either way.
    extension HistoryStore: nonisolated HistoryStoring {
        /// The bytes of one representation, or nil when this store will not hand
        /// them over.
        ///
        /// Nil covers four ordinary answers and no faults: the content was
        /// evicted, the row came from a peer and its payload has not been fetched,
        /// this machine holds the item in some other representation, or the entry
        /// is concealed.
        ///
        /// **Concealed content is filtered here as well as in
        /// ``syncIndex(since:)``.** Omitting it from the index is not enough: a
        /// peer names content by `contentHash`, which is unsalted SHA-256 over the
        /// kind and the text (``ClipItem/hash(kind:text:payload:)``), so a peer
        /// that guesses a secret can ask for its hash without ever having been
        /// offered it. A non-nil answer would confirm the guess and return the
        /// secret in the clear, which is exactly what D-7 says must not cross the
        /// wire.
        public func payload(for contentHash: String, key: RepresentationKey) throws -> Data? {
            guard let record = try recordMatching(contentHash: contentHash) else { return nil }
            guard !record.isConcealed else { return nil }
            let payload = try ClipRecordMapping.decodePayload(record.payloadData)
            for type in Self.localTypes(for: key) {
                if let data = payload.data(forType: type) { return data }
            }
            return nil
        }

        /// Records an item learned from a peer, with whatever payload bytes came
        /// with it.
        ///
        /// **Refuses concealed content**, for the reason `HistoryStore+Merge`'s
        /// `insert(_:into:rejectedConcealed:)` gives: D-7 says concealed items do
        /// not cross the wire, `MergeEngine` has no store to consult, and this is
        /// the receiving half of that rule. Dropping is the whole action.
        ///
        /// Identity is `contentHash`, so a second offer of content already held
        /// adds no second row. It is not a no-op, though: an offer carrying bytes
        /// for a row that has none fills them in — see
        /// ``fillPayload(of:with:)``.
        ///
        /// Writes no tombstone and applies no retention — the same division
        /// `applyRemote(_:)` keeps. Eviction is a local policy decision and does
        /// not belong on the path that learns something.
        public func capture(_ meta: SyncClipMeta, payloads: [RepresentationKey: Data]) throws {
            guard !meta.isConcealed else {
                SkrepkaLog.store.error(
                    "Refused a concealed item offered by a peer; concealed content does not sync."
                )
                return
            }
            let representations = RepresentationKeyMap.utiKeyed(payloads)
            if let existing = try recordMatching(contentHash: meta.contentHash) {
                try fillPayload(of: existing, with: representations)
                return
            }

            let record = try SyncMetaMapping.makeRecord(from: meta)
            if !representations.isEmpty {
                record.payloadData = try ClipRecordMapping.encode(
                    ClipPayload(representations: representations)
                )
            }
            context.insert(record)
            try context.save()
            project(upserts: [record])
        }

        /// Writes payload bytes into a row that was learned from a peer without
        /// any.
        ///
        /// The lazy half of design §7. `SyncMetaMapping.makeRecord` leaves
        /// ``ClipRecord/payloadData`` empty on purpose — metadata is eager, bytes
        /// arrive later on a fetch the transport decides to make — and this is the
        /// only write to that property in `SkrepkaCore`. Without it the fetched
        /// bytes have nowhere to go and the row sits in the picker with a preview
        /// and nothing to paste.
        ///
        /// **A representation that already has bytes is left alone; one that does
        /// not is filled.** Identity is `contentHash`, so a peer can name content
        /// this machine captured itself, and overwriting would let it replace
        /// local bytes with its own — but the unit of that rule is the
        /// representation, not the row.
        ///
        /// Guarding the whole row instead was wrong, and wrong permanently rather
        /// than once. `SyncExchange` can fetch an item's representations in
        /// pieces: its per-round budget can run out mid-item, and a
        /// representation the peer no longer holds comes back as an empty final
        /// chunk. So round one lands the text, `payloadData` stops being empty,
        /// and the RTF that arrives in round two is dropped — while the stored
        /// index still reports it missing, so it is fetched and dropped again
        /// every ``PeerLink/resyncInterval`` for the life of the pairing. The
        /// bytes never land and the bandwidth is spent forever.
        ///
        /// The SQLite engine had this right — its `UPDATE … WHERE bytes IS NULL`
        /// is per representation — and the two disagreeing is the more serious
        /// half: `HistoryStoringContractTests` exists so that the answer to a
        /// question like this is the same on both engines.
        private func fillPayload(of record: ClipRecord, with representations: [String: Data]) throws {
            guard !representations.isEmpty else { return }
            var held: [String: Data] = [:]
            if !record.payloadData.isEmpty {
                held = try ClipRecordMapping.decodePayload(record.payloadData).representations
            }
            // The arrived bytes go *under* what is already held, so a peer cannot
            // replace a representation this machine captured itself, and the ones
            // it has nothing for are filled.
            let merged = held.merging(representations) { local, _ in local }
            guard merged.count > held.count else { return }

            let payload = ClipPayload(representations: merged)
            record.payloadData = try ClipRecordMapping.encode(payload)
            // Merged into the stored index rather than replacing it: a fetch that
            // brought one of two representations must not retract the peer's claim
            // about the other, and what did arrive is measured here rather than
            // trusted from the offer.
            var index: [String: Int] = [:]
            if let stored = record.representationIndex {
                index = try RepresentationIndex.decode(stored)
            }
            index.merge(RepresentationIndex.make(from: payload)) { _, arrived in arrived }
            record.representationIndex = try RepresentationIndex.encode(index)
            try context.save()
            project(upserts: [record])
        }

        /// Pasteboard types that can serve `key`, best first.
        ///
        /// `origin` first because it is the sender's own name for the
        /// representation and is exact when the sender was a Mac. It is a MIME
        /// target when the sender was not, which no macOS payload is keyed by, so
        /// the canonical mapping is the fallback that answers either way.
        private static func localTypes(for key: RepresentationKey) -> [String] {
            [key.origin, RepresentationKeyMap.uti(forCanonical: key.canonical)].compactMap { $0 }
        }
    }

#endif

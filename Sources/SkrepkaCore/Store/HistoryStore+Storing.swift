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
        ///
        /// **Draws the row's picture out of the arriving bytes**, because nothing
        /// else will: no thumbnail crosses the wire — see
        /// `SkrepkaSync.SyncClipMeta`, and `SyncMetaMapping.makeRecord` leaving
        /// ``ClipRecord/thumbnailData`` nil — and the local detail pass never sees
        /// content a peer sent. Without this a synced screenshot draws as a kind
        /// symbol on a text-height row, because the picker asks
        /// ``ClipSummary/hasThumbnail`` before it asks for anything to draw. The
        /// user cannot tell what they are about to paste.
        ///
        /// Rendering from the *arriving* representations rather than from the
        /// merged row is what covers a fetch that splits across rounds — see
        /// ``fillPayload(of:with:)``: whichever round carries the image bytes is
        /// the round that draws them.
        ///
        /// **A row that synced before this shipped stays a symbol.** It already
        /// holds every representation it will ever be offered, so
        /// `SyncExchange.fetchPayloads` finds nothing missing and never calls this
        /// again. Only content arriving from here on gains a picture; correcting
        /// the rows already stored needs a backfill pass this does not have.
        ///
        /// Asynchronous for the reason ``capture(_:)`` is: decoding a picture and
        /// re-encoding it belongs off this actor, and a sync round spends up to
        /// `PeerLink.payloadBudgetPerSync` on payloads, so a first sync against a
        /// picture-heavy peer is several of them back to back.
        ///
        /// **The lookup below, the insert and the save are contiguous and sit
        /// after the last suspension**, and that is the whole of what stops two
        /// peer links learning the same content from both inserting a row for
        /// it. Anything added between them has to be synchronous.
        ///
        /// ``preview(for:from:)`` reads the store as well, before it awaits the
        /// renderer, and that read is advisory: it decides only whether starting
        /// a render is worth it. **Its result must never be carried across the
        /// await and written.** Hoisting it up here to spare the second fetch is
        /// the edit that puts the double insert back, because the row it saw may
        /// have been inserted, filled or deleted by the other link while this one
        /// was decoding.
        public func capture(_ meta: SyncClipMeta, payloads: [RepresentationKey: Data]) async throws {
            guard !meta.isConcealed else {
                SkrepkaLog.store.error(
                    "Refused a concealed item offered by a peer; concealed content does not sync."
                )
                return
            }
            let representations = RepresentationKeyMap.utiKeyed(payloads)
            // Rendered before the context is written to, so no store mutation
            // spans the suspension. The lookup this makes on the way is advisory
            // only — see the note above on what must not be hoisted out of it.
            let preview = try await preview(for: meta, from: representations)

            if let existing = try recordMatching(contentHash: meta.contentHash) {
                try fillPayload(of: existing, with: representations, preview: preview)
                return
            }

            let record = try SyncMetaMapping.makeRecord(from: meta)
            if !representations.isEmpty {
                record.payloadData = try ClipRecordMapping.encode(
                    ClipPayload(representations: representations)
                )
            }
            backfillPreview(preview, into: record)
            context.insert(record)
            try context.save()
            project(upserts: [record])
        }

        /// The picture this offer should draw, or nil when it should draw none.
        ///
        /// Three ways to answer without decoding anything, and each is a real cost
        /// avoided rather than a shortcut.
        ///
        /// **No bytes arrived**, which is the common offer: metadata is eager and
        /// payload is lazy (design §7), so most of what this path sees is an index
        /// the transport has not fetched against yet.
        ///
        /// **The kind cannot be previewed.** ``ThumbnailRenderer/details(for:)``
        /// gates the local pass on ``ClipKind/canPreview`` and this has to gate on
        /// the same thing, or the two machines draw one clip differently. The case
        /// is ordinary rather than contrived: ``PasteboardType/readOrder`` ranks
        /// `rtf`, `html` and `url` above the image types, `CaptureRules.kind(for:)`
        /// takes the first of them present, and `PasteboardReader` stores every
        /// flavour it finds — so a rich-text or link clipping may perfectly well
        /// carry a PNG. Locally it draws no picture; without this guard the peer's
        /// copy of it would, and would take `imageRowHeight` and a `1402 × 578`
        /// subtitle with it.
        ///
        /// Reading the kind off the *offer* is safe because ``ClipKind/hashDomain``
        /// is part of `contentHash`: a row found under this hash cannot be of a
        /// kind that disagrees, except within the file-system group, whose members
        /// carry a `public.file-url` and no image bytes to draw from anyway.
        ///
        /// **The row already has a picture.** A peer re-offering content this
        /// machine drew for itself would otherwise decode and re-encode up to
        /// ``SyncLimits/maximumPayloadBytes`` to produce something
        /// ``backfillPreview(_:into:)`` throws away.
        private func preview(
            for meta: SyncClipMeta,
            from representations: [String: Data]
        ) async throws -> ThumbnailMaker.Preview? {
            guard !representations.isEmpty,
                ClipKind(rawValue: meta.kind)?.canPreview == true,
                try recordMatching(contentHash: meta.contentHash)?.thumbnailData == nil
            else { return nil }
            return await thumbnailRenderer.preview(
                fromImageBytesIn: ClipPayload(representations: representations)
            )
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
        ///
        /// `preview` is whatever picture the arriving bytes held, drawn before the
        /// context was touched. It lands under the same rule the local capture
        /// path uses — see ``backfillPreview(_:into:)`` — and only where bytes did:
        /// a round that brought nothing new leaves the row exactly as it was.
        private func fillPayload(
            of record: ClipRecord,
            with representations: [String: Data],
            preview: ThumbnailMaker.Preview?
        ) throws {
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
            backfillPreview(preview, into: record)
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

// SwiftData is the macOS persistence engine and stays that way (D-3, D-9). Linux
// gets a separate SQLite conformance of HistoryStoring in Phase 4 storage work.
#if canImport(SwiftData)

    import Foundation
    import SkrepkaSync
    import SwiftData
    import os

    /// The clipboard history: persistence, de-duplication, pinning and eviction.
    ///
    /// Main-actor because it owns `ModelContainer.mainContext` and publishes
    /// ``items`` straight to the picker. The projection that keeps ``items`` in
    /// step with the database is in `HistoryStore+Projection.swift`; the sync
    /// surface is in `HistoryStore+Sync.swift`, `HistoryStore+Merge.swift` and
    /// `HistoryStore+Pairing.swift`.
    @MainActor
    @Observable
    public final class HistoryStore {
        /// Newest first, pinned entries hoisted to the top.
        ///
        /// A view of ``projection``, so SwiftUI observes it through that: the
        /// picker's `withObservationTracking` on `items` fires when the store
        /// publishes a new projection, exactly as it did when this was stored.
        public var items: [ClipSummary] { projection.items }

        /// The same list before the hoist, kept so a mutation can be applied as a
        /// delta rather than refetched. See ``ClipProjection``, and
        /// `HistoryStore+Projection.swift` for the one method that writes it.
        var projection = ClipProjection.empty

        #if DEBUG
            /// Turned on by tests: every mutation then re-derives the projection
            /// from the store and records the first disagreement.
            ///
            /// Off in the app's own debug builds, because re-deriving is precisely
            /// the cost `project(upserts:removals:)` exists to avoid.
            var verifiesProjection = false
            /// The first drift seen since ``verifiesProjection`` was turned on.
            var projectionDrift: ProjectionDrift?
        #endif

        public var retention: RetentionPolicy {
            didSet { applyRetention() }
        }

        /// This device's sync identity, once it has one.
        ///
        /// `nil` until the sync stack loads or generates a certificate —
        /// `SyncDeviceID` is SHA-256 over that certificate's DER encoding and
        /// cannot be invented here. While it is `nil` the store still works: it
        /// captures, pins and deletes as usual, but it stamps no origin device on
        /// new rows, writes no tombstones, and ``syncIndex(since:)`` throws
        /// ``HistoryStoreSyncError/deviceIdentityUnavailable``.
        public var localDeviceID: SyncDeviceID?

        private let container: ModelContainer
        private let thumbnailRenderer: ThumbnailRenderer
        var context: ModelContext { container.mainContext }

        /// - Parameter location: where the SQLite store lives, or nil for memory
        ///   only (used by tests).
        public init(
            location: URL?,
            retention: RetentionPolicy = .default,
            thumbnailRenderer: ThumbnailRenderer = ThumbnailRenderer()
        ) throws {
            self.retention = retention
            self.thumbnailRenderer = thumbnailRenderer

            let configuration: ModelConfiguration =
                if let location {
                    ModelConfiguration(url: location)
                } else {
                    ModelConfiguration(isStoredInMemoryOnly: true)
                }
            // Three entities since sync landed. Adding the two new ones and four
            // optional properties to `ClipRecord` is a lightweight migration on
            // macOS 26 — measured against a populated throwaway store, recorded as
            // OQ-9 — so there is deliberately no `SchemaMigrationPlan` here.
            container = try ModelContainer(
                for: ClipRecord.self,
                TombstoneRecord.self,
                PairedDeviceRecord.self,
                configurations: configuration
            )
            reload()
        }

        /// Default on-disk location: `~/Library/Application Support/<bundle-id>/skrepka.store`.
        public static func defaultStoreURL(bundleID: String) throws -> URL {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = support.appending(path: bundleID, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appending(path: "skrepka.store", directoryHint: .notDirectory)
        }

        // MARK: - Capture

        /// Stores a newly captured item, collapsing a repeat copy onto the entry it
        /// duplicates rather than adding a second row.
        ///
        /// Asynchronous because previewing a copied file means reading it, and that
        /// read belongs off this actor — see ``ThumbnailRenderer``. Captures arrive
        /// one at a time from the poller's stream, so the suspension does not
        /// interleave two of them.
        @discardableResult
        public func capture(_ item: ClipItem) async -> Bool {
            // Generated before the context is touched, so no SwiftData work spans
            // the suspension.
            let preview = await thumbnailRenderer.preview(for: item)

            do {
                if let existing = try recordMatching(contentHash: item.contentHash) {
                    existing.createdAt = item.createdAt
                    existing.sourceBundleID = item.sourceBundleID ?? existing.sourceBundleID
                    backfillPreview(preview, into: existing)
                    try context.save()
                    project(upserts: [existing])
                    return true
                }

                let record = try ClipRecordMapping.makeRecord(
                    from: item,
                    preview: preview,
                    originDeviceID: localDeviceID?.hex
                )
                context.insert(record)
                try context.save()
                project(upserts: [record])
                applyRetention()
                return true
            } catch {
                // The list is maintained by delta, so a mutation that threw before
                // it could publish one leaves `items` describing a store that has
                // moved on. Rebuilding is the recovery path — see ``reload()``.
                reload()
                SkrepkaLog.store.error("Failed to store clipboard entry: \(error.localizedDescription)")
                return false
            }
        }

        /// Fills in a preview the entry never got.
        ///
        /// An entry stored before `.file` earned previews has no thumbnail, and so
        /// does one whose file was unreadable at the time. A repeat copy is the only
        /// chance to fix that: nothing else revisits a row, and the de-duplication
        /// above is what a repeat copy hits. Without this those rows keep a generic
        /// document icon for good.
        ///
        /// An existing thumbnail is left alone. The row is a snapshot of the copy
        /// that made it, and replacing it would silently rewrite history.
        private func backfillPreview(_ preview: ThumbnailMaker.Preview?, into record: ClipRecord) {
            guard record.thumbnailData == nil, let preview else { return }
            record.thumbnailData = preview.thumbnail
            record.imageWidth = preview.pixelSize?.width
            record.imageHeight = preview.pixelSize?.height
        }

        // MARK: - Reading

        /// Loads an entry's full payload. Only called when something is pasted.
        public func payload(for id: UUID) -> ClipPayload? {
            do {
                guard let record = try record(withID: id) else { return nil }
                return try ClipRecordMapping.decodePayload(record.payloadData)
            } catch {
                SkrepkaLog.store.error("Failed to load payload: \(error.localizedDescription)")
                return nil
            }
        }

        // MARK: - Mutation

        /// Flips the pin and stamps the last-writer-wins register that carries it
        /// to peers.
        ///
        /// Writing ``ClipRecord/isPinned`` alone would leave the register frozen
        /// at whatever wrote it last, so the pin would never win a merge and the
        /// change would silently fail to propagate.
        public func togglePin(_ id: UUID) {
            mutate(id) { record in
                record.isPinned.toggle()
                record.pinnedAt = Date()
                record.pinnedBy = localDeviceID?.hex
            }
        }

        public func delete(_ id: UUID) {
            do {
                guard let record = try record(withID: id) else { return }
                // Read before the row goes, and `isConcealed` with the hash: a
                // concealed row gets no tombstone, and the only place that is
                // knowable is here.
                let deletion = (contentHash: record.contentHash, isConcealed: record.isConcealed)
                context.delete(record)
                // A deletion is a fact peers have to learn, or the next sync brings
                // it straight back. Eviction is not — see applyRetention().
                try recordDeletions(of: [deletion])
                try context.save()
                project(removals: [id])
            } catch {
                // The removal and its tombstone have to land together or not at
                // all: a row deleted without one is a row the next sync brings
                // back, and `mainContext` autosaves, so a staged delete would
                // commit on its own. Rolling back leaves the entry visible, which
                // the user can act on; the alternative is silent resurrection.
                context.rollback()
                reload()
                SkrepkaLog.store.error("Failed to delete entry: \(error.localizedDescription)")
            }
            // Deletion is what grows the tombstone table, so it is what clears it.
            // After the save, in its own transaction: tidying must not roll back a
            // removal the user asked for.
            pruneExpiredTombstones()
        }

        /// Removes everything, optionally sparing pinned entries.
        public func clear(keepingPinned: Bool = true) {
            do {
                let predicate: Predicate<ClipRecord>? =
                    keepingPinned ? #Predicate { !$0.isPinned } : nil
                // The hashes have to be read before the rows go. That is the whole
                // reason this is no longer a bare bulk delete: clearing history is
                // a deletion, so it writes a tombstone per row — except for the
                // concealed ones, which is why `isConcealed` is read here too. The
                // ids come off the same fetch, because the projection names rows
                // by id.
                let doomed = try context.fetch(FetchDescriptor<ClipRecord>(predicate: predicate))
                let deletions = doomed.map { record in
                    (contentHash: record.contentHash, isConcealed: record.isConcealed)
                }
                let ids = Set(doomed.map(\.id))
                try context.delete(model: ClipRecord.self, where: predicate)
                try recordDeletions(of: deletions)
                try context.save()
                project(removals: ids)
            } catch {
                // Same reason as delete(_:): rows and tombstones land together or
                // not at all.
                context.rollback()
                reload()
                SkrepkaLog.store.error("Failed to clear history: \(error.localizedDescription)")
            }
            // Same reason as delete(_:), and the path that writes the most of them
            // at once.
            pruneExpiredTombstones()
        }

        // MARK: - Internals

        private func mutate(_ id: UUID, _ change: (ClipRecord) -> Void) {
            do {
                guard let record = try record(withID: id) else { return }
                change(record)
                try context.save()
                project(upserts: [record])
            } catch {
                // Same reason as capture(_:): a delta that never got published
                // leaves the list describing a store that has moved on.
                reload()
                SkrepkaLog.store.error("Failed to update entry: \(error.localizedDescription)")
            }
        }

        /// One row by id. Not private: `HistoryStore+Projection.swift` reads a
        /// thumbnail through it when a picker row draws.
        func record(withID id: UUID) throws -> ClipRecord? {
            var descriptor = FetchDescriptor<ClipRecord>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first
        }

        /// The lookup identity across machines. `applyRemote(_:)` runs it for every
        /// action, which is why it is not private.
        func recordMatching(contentHash: String) throws -> ClipRecord? {
            var descriptor = FetchDescriptor<ClipRecord>(
                predicate: #Predicate { $0.contentHash == contentHash }
            )
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first
        }
    }

#endif

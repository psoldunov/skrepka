import Foundation
import SwiftData
import os

/// The clipboard history: persistence, de-duplication, pinning and eviction.
///
/// Main-actor because it owns `ModelContainer.mainContext` and publishes
/// ``items`` straight to the picker.
@MainActor
@Observable
public final class HistoryStore {
    /// Newest first, pinned entries hoisted to the top.
    public private(set) var items: [ClipSummary] = []
    public var retention: RetentionPolicy {
        didSet { applyRetention() }
    }

    private let container: ModelContainer
    private let thumbnailRenderer: ThumbnailRenderer
    private var context: ModelContext { container.mainContext }

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
        container = try ModelContainer(for: ClipRecord.self, configurations: configuration)
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
        let details = await thumbnailRenderer.details(for: item)

        do {
            if let existing = try recordMatching(contentHash: item.contentHash) {
                existing.createdAt = item.createdAt
                existing.sourceBundleID = item.sourceBundleID ?? existing.sourceBundleID
                // A folder stored before Skrepka told folders from files still
                // reads "File". Its hash matches — see ``ClipKind/hashDomain``
                // — so a repeat copy lands here, and this is the one place that
                // can correct it.
                existing.kindRaw = item.kind.rawValue
                // A size the first capture could not take: the entry predates
                // sizes, or the folder was too large to walk that time. An
                // existing measurement is kept when this one came back empty,
                // so a moved file does not lose the size it was copied at.
                existing.byteCount = details.byteCount ?? existing.byteCount
                backfillPreview(details.preview, into: existing)
                try context.save()
                reload()
                return true
            }

            let record = try ClipRecordMapping.makeRecord(from: item, details: details)
            context.insert(record)
            try context.save()
            reload()
            applyRetention()
            return true
        } catch {
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

    public func togglePin(_ id: UUID) {
        mutate(id) { $0.isPinned.toggle() }
    }

    public func delete(_ id: UUID) {
        do {
            guard let record = try record(withID: id) else { return }
            context.delete(record)
            try context.save()
            reload()
        } catch {
            SkrepkaLog.store.error("Failed to delete entry: \(error.localizedDescription)")
        }
    }

    /// Removes everything, optionally sparing pinned entries.
    public func clear(keepingPinned: Bool = true) {
        do {
            let predicate: Predicate<ClipRecord>? =
                keepingPinned ? #Predicate { !$0.isPinned } : nil
            try context.delete(model: ClipRecord.self, where: predicate)
            try context.save()
            reload()
        } catch {
            SkrepkaLog.store.error("Failed to clear history: \(error.localizedDescription)")
        }
    }

    // MARK: - Internals

    private func mutate(_ id: UUID, _ change: (ClipRecord) -> Void) {
        do {
            guard let record = try record(withID: id) else { return }
            change(record)
            try context.save()
            reload()
        } catch {
            SkrepkaLog.store.error("Failed to update entry: \(error.localizedDescription)")
        }
    }

    private func record(withID id: UUID) throws -> ClipRecord? {
        var descriptor = FetchDescriptor<ClipRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func recordMatching(contentHash: String) throws -> ClipRecord? {
        var descriptor = FetchDescriptor<ClipRecord>(
            predicate: #Predicate { $0.contentHash == contentHash }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func reload() {
        do {
            let descriptor = FetchDescriptor<ClipRecord>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            let records = try context.fetch(descriptor)
            let summaries = records.map(ClipRecordMapping.summary(from:))
            items = summaries.filter(\.isPinned) + summaries.filter { !$0.isPinned }
        } catch {
            SkrepkaLog.store.error("Failed to load history: \(error.localizedDescription)")
            items = []
        }
    }

    private func applyRetention() {
        let doomed = retention.idsToEvict(from: items)
        guard !doomed.isEmpty else { return }
        do {
            try context.delete(model: ClipRecord.self, where: #Predicate { doomed.contains($0.id) })
            try context.save()
            reload()
        } catch {
            SkrepkaLog.store.error("Failed to apply retention: \(error.localizedDescription)")
        }
    }
}

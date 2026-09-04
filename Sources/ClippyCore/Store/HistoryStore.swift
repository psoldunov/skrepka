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
    private let thumbnailMaker: ThumbnailMaker
    private var context: ModelContext { container.mainContext }

    /// - Parameter location: where the SQLite store lives, or nil for memory
    ///   only (used by tests).
    public init(
        location: URL?,
        retention: RetentionPolicy = .default,
        thumbnailMaker: ThumbnailMaker = ThumbnailMaker()
    ) throws {
        self.retention = retention
        self.thumbnailMaker = thumbnailMaker

        let configuration: ModelConfiguration =
            if let location {
                ModelConfiguration(url: location)
            } else {
                ModelConfiguration(isStoredInMemoryOnly: true)
            }
        container = try ModelContainer(for: ClipRecord.self, configurations: configuration)
        reload()
    }

    /// Default on-disk location: `~/Library/Application Support/<bundle-id>/clippy.store`.
    public static func defaultStoreURL(bundleID: String) throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appending(path: bundleID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "clippy.store", directoryHint: .notDirectory)
    }

    // MARK: - Capture

    /// Stores a newly captured item, collapsing a repeat copy onto the entry it
    /// duplicates rather than adding a second row.
    @discardableResult
    public func capture(_ item: ClipItem) -> Bool {
        do {
            if let existing = try recordMatching(contentHash: item.contentHash) {
                existing.createdAt = item.createdAt
                existing.sourceBundleID = item.sourceBundleID ?? existing.sourceBundleID
                try context.save()
                reload()
                return true
            }

            let preview = item.kind == .image ? thumbnailMaker.makePreview(from: item.payload) : nil
            let record = try ClipRecordMapping.makeRecord(from: item, preview: preview)
            context.insert(record)
            try context.save()
            reload()
            applyRetention()
            return true
        } catch {
            ClippyLog.store.error("Failed to store clipboard entry: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Reading

    /// Loads an entry's full payload. Only called when something is pasted.
    public func payload(for id: UUID) -> ClipPayload? {
        do {
            guard let record = try record(withID: id) else { return nil }
            return try ClipRecordMapping.decodePayload(record.payloadData)
        } catch {
            ClippyLog.store.error("Failed to load payload: \(error.localizedDescription)")
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
            ClippyLog.store.error("Failed to delete entry: \(error.localizedDescription)")
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
            ClippyLog.store.error("Failed to clear history: \(error.localizedDescription)")
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
            ClippyLog.store.error("Failed to update entry: \(error.localizedDescription)")
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
            ClippyLog.store.error("Failed to load history: \(error.localizedDescription)")
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
            ClippyLog.store.error("Failed to apply retention: \(error.localizedDescription)")
        }
    }
}

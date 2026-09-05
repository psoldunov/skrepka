// What is left of the SwiftData store's sync surface once `HistoryStoringTests`
// has it: everything the two engines share is asserted there, against every
// conformance, and duplicating it here would mean a behaviour change showing up
// as two failures on macOS and one on Linux.
//
// The representation index is not shared. It is a denormalised column on
// `ClipRecord` that the SQLite schema deliberately has no equivalent of — byte
// counts live in `clip_representation` beside the bytes they describe — so
// backfilling one is a SwiftData-only question and this is the only place it can
// be asked.
#if canImport(SwiftData)

    import Foundation
    import SkrepkaSync
    import SwiftData
    import Testing

    @testable import SkrepkaCore

    @Suite("History store representation index")
    @MainActor
    struct HistoryStoreSyncTests {
        private let epoch = Date(timeIntervalSince1970: 900_000)

        private func at(_ offset: TimeInterval) -> Date { epoch.addingTimeInterval(offset) }

        @Test("A row written before representationIndex existed is backfilled, not skipped")
        func backfillsRowsWrittenBeforeTheIndexExisted() async throws {
            let store = try SyncFixtures.makeStore()
            #expect(await store.capture(SyncFixtures.item("legacy", at: at(1))))

            // What a pre-sync row looks like: payload present, index absent.
            let record = try #require(
                try store.recordMatching(contentHash: SyncFixtures.contentHash("legacy"))
            )
            record.representationIndex = nil
            try store.context.save()

            let entry = try #require(try store.syncIndex(since: nil).first)
            #expect(entry.representations == [SyncFixtures.plainTextDescriptor(byteCount: 6)])
            // Backfilled rather than recomputed on every index: the answer is
            // written back, so the external-storage read is paid once per row.
            #expect(record.representationIndex != nil)
        }
    }

#endif

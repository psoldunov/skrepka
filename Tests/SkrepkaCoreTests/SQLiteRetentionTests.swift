// Retention changed while the store is open — the Linux daemon's Settings
// window and `skrepka config set`. Fenced to Linux with the engine it tests.
#if os(Linux)

    import Foundation
    import SkrepkaSync
    import Testing

    @testable import SkrepkaCore

    @Suite("SQLite retention at runtime")
    struct SQLiteRetentionTests {
        private static func store(holding count: Int) async throws -> SQLiteHistoryStore {
            let store = try SQLiteHistoryStore(
                location: nil,
                retention: .unlimited,
                localDeviceID: EngineFixtures.localDevice
            )
            for index in 0..<count {
                let item = EngineFixtures.item("entry \(index)", at: EngineFixtures.at(Double(index)))
                #expect(await store.capture(item))
            }
            return store
        }

        @Test("a lowered cap evicts at once, oldest first, and keeps pinned entries")
        func aLoweredCapEvictsImmediately() async throws {
            let store = try await Self.store(holding: 5)
            let oldest = try #require(try await store.summaries().last)
            await store.togglePin(oldest.id)

            let evicted = try await store.setRetention(
                RetentionPolicy(maximumItems: 2, maximumAge: nil), now: EngineFixtures.at(10))

            #expect(evicted == 2)
            let texts = try await store.summaries().map(\.text)
            #expect(texts == ["entry 0", "entry 4", "entry 3"])
            #expect(await store.retentionPolicy.maximumItems == 2)
        }

        /// The rule `applyRetention` documents at length: a cap is local, and a
        /// tombstone would carry it to every peer.
        @Test("eviction from a changed cap writes no tombstones")
        func aLoweredCapWritesNoTombstones() async throws {
            let store = try await Self.store(holding: 4)
            try await store.setRetention(
                RetentionPolicy(maximumItems: 1, maximumAge: nil), now: EngineFixtures.at(10))
            #expect(try await store.summaries().count == 1)
            #expect(try await store.tombstones(since: nil).isEmpty)
        }

        @Test("a raised cap evicts nothing")
        func aRaisedCapEvictsNothing() async throws {
            let store = try await Self.store(holding: 3)
            let evicted = try await store.setRetention(
                RetentionPolicy(maximumItems: 10, maximumAge: nil), now: EngineFixtures.at(10))
            #expect(evicted == 0)
            #expect(try await store.summaries().count == 3)
        }

        @Test("the sweep ages entries out with nothing captured")
        func theSweepAgesEntriesOut() async throws {
            let store = try await Self.store(holding: 3)
            try await store.setRetention(
                RetentionPolicy(maximumItems: nil, maximumAge: 100), now: EngineFixtures.at(10))
            #expect(try await store.summaries().count == 3)

            let evicted = try await store.sweepRetention(now: EngineFixtures.at(101.5))
            #expect(evicted == 2)
            #expect(try await store.summaries().map(\.text) == ["entry 2"])
            #expect(try await store.tombstones(since: nil).isEmpty)
        }

        @Test("counts report entries, pinned entries and pictures")
        func countsReportTheHistory() async throws {
            let store = try await Self.store(holding: 2)
            let picture = ClipItem(
                kind: .image,
                text: "picture",
                payload: ClipPayload(representations: [PasteboardType.png: Data([1, 2, 3])]),
                createdAt: EngineFixtures.at(5)
            )
            #expect(await store.capture(picture))
            let first = try #require(try await store.summaries().first)
            await store.togglePin(first.id)

            let counts = try await store.counts()
            #expect(counts.entries == 3)
            #expect(counts.pinned == 1)
            #expect(counts.pictures == 1)
        }
    }

#endif

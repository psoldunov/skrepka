import Foundation
import SkrepkaSync
import Testing

@testable import SkrepkaCore

/// One suite, run against every history store this build has.
///
/// That is the whole reason `HistoryStoring` was pulled forward into
/// `SkrepkaSync`: macOS keeps SwiftData and Linux gets raw SQLite (D-3, D-9), and
/// two engines cost three things that only a shared suite holds down —
///
/// - **The schema is defined twice.** A column added on one side and forgotten on
///   the other is the failure mode; ``everyStoredColumnSurvivesARoundTrip``
///   reads every one of them back.
/// - **Each conformance owns its own mapping.** `ClipRecordMapping` and
///   `SyncMetaMapping` belong to SwiftData, `SQLiteClipMapping` to SQLite;
///   ``theIndexDescribesWhatAPeerNeeds`` in `HistoryStoringSyncTests` compares
///   what the two produce against the same fixture.
/// - **Semantics can drift** — sort order, what a nil column means, transaction
///   boundaries. ``orderingIsTheSameOnEveryRead`` and
///   ``anEntryWithNoOptionalColumnsSetReadsBackAsNil`` are the guards.
///
/// The sync surface is in `HistoryStoringSyncTests.swift`, paired peers in
/// `HistoryStoringPairingTests.swift` and the files a multi-file copy holds in
/// `HistoryStoringSelectionTests.swift` — all extensions of this suite.
@Suite("History storing, against every engine")
struct HistoryStoringTests {
    static func makeStore(
        _ engine: HistoryStoreEngine,
        retention: RetentionPolicy = .unlimited,
        deviceID: SyncDeviceID? = EngineFixtures.localDevice
    ) async throws -> any HistoryStoreConforming {
        try await engine.make(retention, deviceID)
    }

    // MARK: - Capture and listing

    @Test("A captured item is listed", arguments: HistoryStoreEngine.all)
    func captureStoresAnItem(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        #expect(await store.capture(EngineFixtures.item("hello", at: EngineFixtures.at(1))))

        let summaries = try await store.summaries()
        #expect(summaries.map(\.text) == ["hello"])
        #expect(summaries.first?.createdAt == EngineFixtures.at(1))
    }

    @Test("A repeat copy collapses onto the entry it duplicates", arguments: HistoryStoreEngine.all)
    func repeatCopyCollapses(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        #expect(await store.capture(EngineFixtures.item("same", at: EngineFixtures.at(1))))
        #expect(await store.capture(EngineFixtures.item("other", at: EngineFixtures.at(2))))
        #expect(await store.capture(EngineFixtures.item("same", at: EngineFixtures.at(3))))

        // One row, moved to the top rather than duplicated.
        let summaries = try await store.summaries()
        #expect(summaries.map(\.text) == ["same", "other"])
        #expect(summaries.first?.createdAt == EngineFixtures.at(3))
    }

    @Test("Pinned entries are hoisted above newer unpinned ones", arguments: HistoryStoreEngine.all)
    func pinnedEntriesAreHoisted(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        #expect(await store.capture(EngineFixtures.item("old", at: EngineFixtures.at(1))))
        #expect(await store.capture(EngineFixtures.item("new", at: EngineFixtures.at(2))))

        let old = try #require(try await store.summaries().last)
        await store.togglePin(old.id)

        #expect(try await store.summaries().map(\.text) == ["old", "new"])
    }

    /// Sort stability is one of the three costs two engines carry, and the one
    /// that would show up as a flaky suite rather than a failing one.
    ///
    /// SwiftData documents no tie-break for `SortDescriptor(\.createdAt,
    /// order: .reverse)`; it was *measured* returning insertion order, and the
    /// SQLite store's `ORDER BY created_at DESC, rowid ASC` was chosen to match
    /// what it does rather than the other way round. Asserting the exact order
    /// here is what turns a future change of SwiftData's mind into a red test on
    /// macOS instead of two stores that quietly disagree about the top of the
    /// history.
    @Test("Entries sharing an instant order the same way everywhere", arguments: HistoryStoreEngine.all)
    func orderingIsTheSameOnEveryRead(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        for text in ["first", "second", "third"] {
            #expect(await store.capture(EngineFixtures.item(text, at: EngineFixtures.at(1))))
        }

        let order = try await store.summaries().map(\.text)
        #expect(order == ["first", "second", "third"])
        // And it does not change between reads, which is the half that would make
        // every other assertion in this suite unreliable.
        #expect(try await store.summaries().map(\.text) == order)
        #expect(try await store.summaries().map(\.text) == order)
    }

    // MARK: - Payload

    @Test("A payload round trips, and an unknown id has none", arguments: HistoryStoreEngine.all)
    func payloadRoundTrips(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        #expect(await store.capture(EngineFixtures.item("bytes", at: EngineFixtures.at(1))))

        let id = try #require(try await store.summaries().first?.id)
        let payload = try #require(await store.contents(for: id)).payload
        #expect(payload.data(forType: PasteboardType.string) == Data("bytes".utf8))

        // nil means "no such entry" — distinct from an entry that holds no bytes,
        // which is an empty payload. The two answers are what a peer's fetch
        // distinguishes.
        #expect(await store.contents(for: UUID()) == nil)
    }

    // MARK: - Schema parity

    @Test("Every stored column survives a round trip", arguments: HistoryStoreEngine.all)
    func everyStoredColumnSurvivesARoundTrip(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        let item = ClipItem(
            kind: .image,
            text: "screenshot",
            payload: ClipPayload(representations: [PasteboardType.png: Data("not-a-png".utf8)]),
            sourceBundleID: "com.example.app",
            createdAt: EngineFixtures.at(7),
            isConcealed: false,
            imageSize: ClipItem.ImageSize(width: 640, height: 480)
        )
        #expect(await store.capture(item))
        let summary = try #require(try await store.summaries().first)

        #expect(summary.id == item.id)
        #expect(summary.kind == .image)
        #expect(summary.text == "screenshot")
        #expect(summary.sourceBundleID == "com.example.app")
        #expect(summary.createdAt == EngineFixtures.at(7))
        #expect(summary.isPinned == false)
        #expect(summary.isConcealed == false)
        #expect(summary.imageSize == ClipItem.ImageSize(width: 640, height: 480))
        // No thumbnail on either engine: the bytes do not decode as a picture on
        // macOS, and Linux has no renderer until Phase 7 (D-9).
        #expect(!summary.hasThumbnail)

        // The sync columns, read back through the other mapping.
        let meta = try #require(try await store.syncIndex(since: nil).first)
        #expect(meta.contentHash == item.contentHash)
        #expect(meta.kind == ClipKind.image.rawValue)
        #expect(meta.imageWidth == 640)
        #expect(meta.imageHeight == 480)
        #expect(meta.sourceBundleID == "com.example.app")
        #expect(meta.originDeviceID == EngineFixtures.localDevice)
    }

    @Test("An entry with no optional columns set reads back as nil", arguments: HistoryStoreEngine.all)
    func anEntryWithNoOptionalColumnsSetReadsBackAsNil(engine: HistoryStoreEngine) async throws {
        // Captured before this machine had a sync identity, so `origin_device_id`,
        // `pinned_at` and `pinned_by` are all unset — the case a store that wrote
        // an empty string instead of a NULL would fail.
        let store = try await Self.makeStore(engine, deviceID: nil)
        #expect(await store.capture(EngineFixtures.item("anonymous", at: EngineFixtures.at(1))))

        let summary = try #require(try await store.summaries().first)
        #expect(summary.sourceBundleID == nil)
        #expect(summary.imageSize == nil)
        #expect(!summary.hasThumbnail)

        // A row that names no device is described as this one's, and a pin that
        // was never written falls back to createdAt rather than to the clock.
        await store.setLocalDeviceID(EngineFixtures.localDevice)
        let meta = try #require(try await store.syncIndex(since: nil).first)
        #expect(meta.originDeviceID == EngineFixtures.localDevice)
        #expect(meta.isPinned.deviceID == EngineFixtures.localDevice)
        #expect(meta.isPinned.timestamp == EngineFixtures.at(1))
    }

    // MARK: - Deletion, and the difference from eviction

    @Test("Deleting an entry writes a tombstone", arguments: HistoryStoreEngine.all)
    func deleteWritesATombstone(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        #expect(await store.capture(EngineFixtures.item("goodbye", at: EngineFixtures.at(1))))
        let doomed = try #require(try await store.summaries().first?.id)
        await store.delete(doomed)

        let tombstones = try await store.tombstones(since: nil)
        #expect(tombstones.map(\.contentHash) == [EngineFixtures.contentHash("goodbye")])
        #expect(tombstones.first?.deviceID == EngineFixtures.localDevice)
        #expect(try await store.summaries().isEmpty)
    }

    @Test("Clearing history writes a tombstone per entry it removed", arguments: HistoryStoreEngine.all)
    func clearWritesABatchOfTombstones(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        #expect(await store.capture(EngineFixtures.item("one", at: EngineFixtures.at(1))))
        #expect(await store.capture(EngineFixtures.item("two", at: EngineFixtures.at(2))))
        #expect(await store.capture(EngineFixtures.item("three", at: EngineFixtures.at(3))))
        let pinned = try #require(try await store.summaries().last?.id)
        await store.togglePin(pinned)

        await store.clear(keepingPinned: true)

        #expect(try await store.summaries().map(\.text) == ["one"])
        // Two removed, two tombstones — and none for the entry that survived.
        let hashes = Set(try await store.tombstones(since: nil).map(\.contentHash))
        #expect(hashes == [EngineFixtures.contentHash("two"), EngineFixtures.contentHash("three")])
    }

    /// The most important test in the phase. Conflating eviction with deletion is
    /// how a sync feature quietly destroys history: a 500-item cap on this machine
    /// would wipe a peer configured to keep 5000, permanently.
    @Test("Retention evicts without writing a tombstone", arguments: HistoryStoreEngine.all)
    func retentionWritesNoTombstone(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(
            engine,
            retention: RetentionPolicy(maximumItems: 1, maximumAge: nil)
        )
        #expect(await store.capture(EngineFixtures.item("first", at: EngineFixtures.at(1))))
        #expect(await store.capture(EngineFixtures.item("second", at: EngineFixtures.at(2))))

        #expect(try await store.summaries().map(\.text) == ["second"])
        #expect(try await store.tombstones(since: nil).isEmpty)
    }
}

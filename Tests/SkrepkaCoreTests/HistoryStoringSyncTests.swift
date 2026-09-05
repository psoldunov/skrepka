import Foundation
import SkrepkaSync
import Testing

@testable import SkrepkaCore

/// The sync surface of ``HistoryStoringTests`` — the six `HistoryStoring`
/// requirements, run against every engine.
///
/// An extension rather than a second suite so the whole store surface reports as
/// one thing: a behaviour that differs between engines should fail *the* suite,
/// not a suite a reader has to know to look for.
extension HistoryStoringTests {
    // MARK: - Offering

    /// Unconditional per D-7: concealed items do not cross the wire in v1 and
    /// there is no preference that lets them through, so there is no second case
    /// to test.
    @Test("A concealed entry never appears in the sync index", arguments: HistoryStoreEngine.all)
    func syncIndexOmitsConcealed(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        #expect(await store.capture(EngineFixtures.item("visible", at: EngineFixtures.at(1))))
        #expect(
            await store.capture(
                EngineFixtures.item("hunter2", concealed: true, at: EngineFixtures.at(2))
            )
        )
        #expect(try await store.summaries().count == 2)

        #expect(try await store.syncIndex(since: nil).map(\.preview) == ["visible"])
    }

    @Test("The index describes what a peer needs and nothing more", arguments: HistoryStoreEngine.all)
    func theIndexDescribesWhatAPeerNeeds(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        #expect(await store.capture(EngineFixtures.item("hello", at: EngineFixtures.at(1))))

        let entry = try #require(try await store.syncIndex(since: nil).first)
        #expect(entry.preview == "hello")
        #expect(entry.kind == ClipKind.text.rawValue)
        #expect(entry.createdAt == EngineFixtures.at(1))
        #expect(entry.originDeviceID == EngineFixtures.localDevice)
        #expect(entry.isPinned.value == false)
        // Each engine builds this through its own mapping — `SyncMetaMapping` on
        // one side, `SQLiteClipMapping` on the other — from its own
        // representation index. Same fixture, same answer, or one of them drifted.
        #expect(entry.representations == [EngineFixtures.plainTextDescriptor(byteCount: 5)])
    }

    @Test("A cursor returns only what was captured after it", arguments: HistoryStoreEngine.all)
    func syncIndexHonoursCursor(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        #expect(await store.capture(EngineFixtures.item("old", at: EngineFixtures.at(1))))
        #expect(await store.capture(EngineFixtures.item("new", at: EngineFixtures.at(2))))

        #expect(try await store.syncIndex(since: EngineFixtures.at(1)).map(\.preview) == ["new"])
        #expect(try await store.syncIndex(since: nil).map(\.preview) == ["old", "new"])
    }

    @Test("A store with no device identity refuses to describe itself", arguments: HistoryStoreEngine.all)
    func syncIndexNeedsADeviceIdentity(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine, deviceID: nil)
        #expect(await store.capture(EngineFixtures.item("hello", at: EngineFixtures.at(1))))
        await #expect(throws: HistoryStoreSyncError.deviceIdentityUnavailable) {
            try await store.syncIndex(since: nil)
        }
    }

    @Test("Toggling a pin stamps the register that carries it to peers", arguments: HistoryStoreEngine.all)
    func togglingAPinStampsTheRegister(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        #expect(await store.capture(EngineFixtures.item("pin me", at: EngineFixtures.at(1))))
        let id = try #require(try await store.summaries().first?.id)
        await store.togglePin(id)

        let entry = try #require(try await store.syncIndex(since: nil).first)
        #expect(entry.isPinned.value)
        #expect(entry.isPinned.deviceID == EngineFixtures.localDevice)
        #expect(entry.isPinned.timestamp > EngineFixtures.at(1))
    }

    // MARK: - Payload transfer

    @Test("A peer's item is stored with whatever bytes came with it", arguments: HistoryStoreEngine.all)
    func captureFromAPeerStoresBytesAndIndex(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        let meta = EngineFixtures.meta("from a peer")
        let bytes = Data("from a peer".utf8)
        try await store.capture(meta, payloads: [EngineFixtures.plainTextKey: bytes])

        #expect(try await store.summaries().map(\.text) == ["from a peer"])
        #expect(try await store.payload(for: meta.contentHash, key: EngineFixtures.plainTextKey) == bytes)
        // The bytes arrived with it, so the offer can promise them.
        let entry = try #require(try await store.syncIndex(since: nil).first)
        #expect(entry.representations == meta.representations)
    }

    @Test("Bytes this store does not hold are nil, not an error", arguments: HistoryStoreEngine.all)
    func payloadIsNilForBytesThisStoreDoesNotHold(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        let meta = EngineFixtures.meta("metadata only")
        // Metadata is eager and payload is lazy (design §7), so this is the
        // ordinary state of a freshly merged row rather than a corrupt one.
        try await store.capture(meta, payloads: [:])

        #expect(try await store.payload(for: meta.contentHash, key: EngineFixtures.plainTextKey) == nil)
        #expect(try await store.payload(for: "never-heard-of-it", key: EngineFixtures.plainTextKey) == nil)
        // Still described — the metadata is worth merging — and promising nothing,
        // because it can serve nothing. The other end is in the fill-in case below.
        #expect(try await store.syncIndex(since: nil).first?.representations.isEmpty == true)
    }

    @Test("A concealed item offered to capture is dropped, not stored", arguments: HistoryStoreEngine.all)
    func captureFromAPeerRefusesConcealedContent(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        try await store.capture(EngineFixtures.meta("hunter2", concealed: true), payloads: [:])

        #expect(try await store.summaries().isEmpty)
    }

    /// Omitting concealed content from the index is not enough. `contentHash` is
    /// unsalted SHA-256 over the kind and the text, so a peer can compute one for
    /// a guessed secret and ask for it without ever having been offered it — and
    /// a non-nil answer would both confirm the guess and hand back the secret.
    @Test("A concealed entry's bytes are never served to a peer", arguments: HistoryStoreEngine.all)
    func payloadIsNilForConcealedContent(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        #expect(
            await store.capture(
                EngineFixtures.item("hunter2", concealed: true, at: EngineFixtures.at(1))
            )
        )

        // Held locally and pasteable from the picker; invisible to sync on both
        // paths that could emit it.
        #expect(try await store.summaries().map(\.text) == ["hunter2"])
        #expect(try await store.syncIndex(since: nil).isEmpty)
        #expect(
            try await store.payload(
                for: EngineFixtures.contentHash("hunter2"),
                key: EngineFixtures.plainTextKey
            ) == nil
        )
    }

    /// The transition the two cases above cover only the ends of: metadata is
    /// eager and payload is lazy (design §7), so the row lands empty and the
    /// transport fetches the bytes afterwards. A second capture is the only way
    /// they can arrive.
    ///
    /// It is also where the offer changes, and both engines have to change it at
    /// the same instant. `SyncClipMeta.representations` claims what its owner can
    /// serve: Mac A holds an item as text and PDF, Linux B learns it and fetches
    /// only the text, and B advertising the PDF to Mac C promises bytes C will ask
    /// B for and B cannot send. The row keeps the peer's claim internally — one
    /// with nothing to request syncs as a ghost — so this is the offering side.
    @Test("Bytes fetched later fill in a row learned from a peer", arguments: HistoryStoreEngine.all)
    func captureFillsInAPayloadFetchedLater(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        let meta = EngineFixtures.meta("from a peer")
        let bytes = Data("from a peer".utf8)
        try await store.capture(meta, payloads: [:])
        #expect(try await store.syncIndex(since: nil).first?.representations.isEmpty == true)

        try await store.capture(meta, payloads: [EngineFixtures.plainTextKey: bytes])

        // One row, now with something to paste — and now worth offering bytes for.
        #expect(try await store.summaries().map(\.text) == ["from a peer"])
        #expect(try await store.payload(for: meta.contentHash, key: EngineFixtures.plainTextKey) == bytes)
        #expect(try await store.syncIndex(since: nil).first?.representations == meta.representations)
    }

    /// Identity is `contentHash`, so a peer can name content this machine
    /// captured itself. Filling in absent bytes must not become a way to replace
    /// bytes that are there.
    @Test(
        "A later capture never overwrites payload bytes this store holds",
        arguments: HistoryStoreEngine.all
    )
    func captureNeverOverwritesHeldBytes(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        #expect(await store.capture(EngineFixtures.item("mine", at: EngineFixtures.at(1))))
        let meta = EngineFixtures.meta("mine")
        try await store.capture(meta, payloads: [EngineFixtures.plainTextKey: Data("theirs".utf8)])

        #expect(try await store.summaries().count == 1)
        #expect(
            try await store.payload(for: meta.contentHash, key: EngineFixtures.plainTextKey)
                == Data("mine".utf8)
        )
    }

    // MARK: - Tombstones

    @Test("A tombstone folds into one already held for the same content", arguments: HistoryStoreEngine.all)
    func recordTombstoneMergesByContent(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        let early = Tombstone(
            contentHash: "abc",
            deletedAt: EngineFixtures.at(1),
            deviceID: EngineFixtures.localDevice
        )
        let late = Tombstone(
            contentHash: "abc",
            deletedAt: EngineFixtures.at(2),
            deviceID: EngineFixtures.peerDevice
        )
        try await store.recordTombstone(late)
        try await store.recordTombstone(early)

        // The later deletion wins in either arrival order — the conservative
        // direction, since erring the other way brings back deleted content.
        #expect(try await store.tombstones(since: nil) == [late])
        #expect(try await store.tombstones(since: EngineFixtures.at(2)).isEmpty)
    }

    // MARK: - Receiving

    @Test("Applying the same plan twice changes nothing the second time", arguments: HistoryStoreEngine.all)
    func applyRemoteIsIdempotent(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        // Later than the metadata's own createdAt, or the bump is correctly a
        // no-op and the test proves nothing.
        let bumped = Date(timeIntervalSince1970: 2_000_000)
        let shared = EngineFixtures.meta("from a peer")
        let plan: [MergeAction] = [
            .insert(shared),
            .insert(EngineFixtures.meta("also from a peer", pinned: true)),
            .recordTombstone(
                Tombstone(
                    contentHash: "deleted-elsewhere",
                    deletedAt: EngineFixtures.at(1),
                    deviceID: EngineFixtures.peerDevice
                )
            ),
            .bumpCreatedAt(contentHash: shared.contentHash, to: bumped),
            .applyPin(
                contentHash: shared.contentHash,
                register: LWWRegister(
                    value: true,
                    timestamp: bumped,
                    deviceID: EngineFixtures.peerDevice
                )
            ),
        ]

        try await store.applyRemote(plan)
        let first = try await store.syncIndex(since: nil)
        let firstTombstones = try await store.tombstones(since: nil)

        try await store.applyRemote(plan)

        #expect(try await store.syncIndex(since: nil) == first)
        #expect(try await store.tombstones(since: nil) == firstTombstones)
        #expect(try await store.summaries().count == 2)
        #expect(first.first { $0.contentHash == shared.contentHash }?.createdAt == bumped)
    }

    /// Load-bearing, not defence in depth: `MergeEngine.plan` has no store to
    /// consult and no policy to apply, so it will emit `.insert` for metadata a
    /// hostile or buggy peer marked concealed.
    @Test("A concealed item offered by a peer is dropped, not stored", arguments: HistoryStoreEngine.all)
    func applyRemoteRefusesConcealedContent(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        try await store.applyRemote([
            .insert(EngineFixtures.meta("hunter2", concealed: true)),
            .insert(EngineFixtures.meta("ordinary")),
        ])

        #expect(try await store.summaries().map(\.text) == ["ordinary"])
        #expect(try await store.syncIndex(since: nil).map(\.preview) == ["ordinary"])
    }

    @Test("An update never moves a row backwards in time", arguments: HistoryStoreEngine.all)
    func applyRemoteNeverMovesARowBackwards(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        let late = EngineFixtures.meta("shared", at: EngineFixtures.at(5_000))
        try await store.applyRemote([.insert(late)])
        try await store.applyRemote([
            .bumpCreatedAt(contentHash: late.contentHash, to: EngineFixtures.at(1))
        ])

        #expect(try await store.syncIndex(since: nil).first?.createdAt == late.createdAt)
    }

    @Test("A live tombstone removes content this store still holds", arguments: HistoryStoreEngine.all)
    func applyRemoteDeletesLocally(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        #expect(await store.capture(EngineFixtures.item("doomed", at: EngineFixtures.at(1))))
        try await store.applyRemote([
            .deleteLocally(contentHash: EngineFixtures.contentHash("doomed"))
        ])

        #expect(try await store.summaries().isEmpty)
        // No tombstone of its own: the plan carries `.recordTombstone` separately,
        // and writing one here would restamp somebody else's deletion with this
        // device's clock and identity.
        #expect(try await store.tombstones(since: nil).isEmpty)
    }
}

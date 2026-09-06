import Foundation
import SkrepkaProbe
import Testing

@testable import SkrepkaSync

/// One suite, run against every ``HistoryStoring`` conformance that is not a
/// clipboard history.
///
/// The phase document asks for `HistoryStoringTests` to run against
/// `ProbeStore`. It cannot, and the reason is worth stating rather than working
/// around: that suite lives in `SkrepkaCoreTests` and drives `ClipItem`,
/// retention, pinning and projection — things `HistoryStoring` deliberately does
/// not have and `ProbeStore` therefore does not implement. What *can* be shared
/// is this: the six methods the protocol actually declares, and the rules its
/// documentation states about them. So the assertions are the same and the
/// surface is the narrow one.
///
/// `SkrepkaCoreTests.HistoryStoringTests` still runs the wider suite against
/// every real history engine, and between the two every conformance in the
/// build is covered.
@Suite("History storing contract")
struct HistoryStoringContractTests {
    static let device = SyncDeviceID(certificateDER: Data("contract-device".utf8))
    static let key = RepresentationKey(canonical: "text/plain;charset=utf-8")
    static let epoch = Date(timeIntervalSince1970: 1_700_000)

    /// One conformance, and how to build a fresh empty one.
    struct Engine: Sendable, CustomTestStringConvertible {
        let name: String
        let make: @Sendable () async throws -> any HistoryStoring

        var testDescription: String { name }

        static let all: [Engine] = [
            Engine(name: "FakeHistoryStore") { FakeHistoryStore() },
            Engine(name: "ProbeStore") {
                // A directory per store, removed by the process exiting. A shared
                // one would have two tests write one file.
                try ProbeStore(url: Engine.scratchDirectory().appending(path: "history.json"))
            },
        ]

        private static func scratchDirectory() -> URL {
            FileManager.default.temporaryDirectory
                .appending(path: "skrepka-contract-\(UUID().uuidString)")
        }
    }

    // MARK: - Offering and learning

    @Test("An item learned from a peer is offered back", arguments: Engine.all)
    func aLearnedItemIsOffered(engine: Engine) async throws {
        let store = try await engine.make()
        let bytes = Data("hello".utf8)
        try await store.capture(Self.meta("hello", bytes: bytes), payloads: [Self.key: bytes])

        let index = try await store.syncIndex(since: nil)
        #expect(index.map(\.preview) == ["hello"])
        #expect(try await store.payload(for: index[0].contentHash, key: Self.key) == bytes)
    }

    /// Identity is `contentHash`, so a second offer of content already held adds
    /// no second row — and does not overwrite bytes the store already has, or a
    /// peer could replace content this device captured itself.
    @Test("A second offer of held content adds no row and keeps the bytes", arguments: Engine.all)
    func aSecondOfferIsIdempotent(engine: Engine) async throws {
        let store = try await engine.make()
        let mine = Data("mine".utf8)
        try await store.capture(Self.meta("hello", bytes: mine), payloads: [Self.key: mine])
        try await store.capture(
            Self.meta("hello", bytes: mine),
            payloads: [Self.key: Data("theirs".utf8)]
        )

        let index = try await store.syncIndex(since: nil)
        #expect(index.count == 1)
        #expect(try await store.payload(for: index[0].contentHash, key: Self.key) == mine)
    }

    /// **The rule the protocol exists to state.** A `contentHash` names content
    /// without carrying it, so a peer can ask for one it was never offered, and a
    /// conformance that answered by hash alone would confirm a guessed secret as
    /// well as serve it.
    @Test("Concealed content is filtered from the index and the payload", arguments: Engine.all)
    func concealedContentNeverLeaves(engine: Engine) async throws {
        let store = try await engine.make()
        let secret = Data("hunter2".utf8)
        let meta = Self.meta("hunter2", bytes: secret, isConcealed: true)
        // Offered by a peer, which every conformance must refuse outright.
        try await store.capture(meta, payloads: [Self.key: secret])

        #expect(try await store.syncIndex(since: nil).isEmpty)
        #expect(try await store.payload(for: meta.contentHash, key: Self.key) == nil)
    }

    @Test("A payload nobody holds is nil rather than an error", arguments: Engine.all)
    func anUnknownPayloadIsNil(engine: Engine) async throws {
        let store = try await engine.make()
        #expect(try await store.payload(for: String(repeating: "f", count: 64), key: Self.key) == nil)
    }

    /// A cursor is the caller's way of asking for what is new, and both ends of
    /// the protocol assume it means *strictly* after.
    @Test("A cursor returns only what was created after it", arguments: Engine.all)
    func theCursorIsExclusive(engine: Engine) async throws {
        let store = try await engine.make()
        let old = Self.meta("old", bytes: Data("old".utf8), at: Self.epoch)
        let new = Self.meta("new", bytes: Data("new".utf8), at: Self.epoch.addingTimeInterval(60))
        try await store.capture(old, payloads: [:])
        try await store.capture(new, payloads: [:])

        #expect(try await store.syncIndex(since: Self.epoch).map(\.preview) == ["new"])
        #expect(try await store.syncIndex(since: nil).count == 2)
    }

    // MARK: - Tombstones

    @Test("A tombstone round trips and folds into one already held", arguments: Engine.all)
    func aTombstoneFolds(engine: Engine) async throws {
        let store = try await engine.make()
        let hash = String(repeating: "a", count: 64)
        let earlier = Tombstone(contentHash: hash, deletedAt: Self.epoch, deviceID: Self.device)
        let later = Tombstone(
            contentHash: hash,
            deletedAt: Self.epoch.addingTimeInterval(60),
            deviceID: Self.device
        )
        try await store.recordTombstone(later)
        try await store.recordTombstone(earlier)

        // One record, and the later deletion is the one kept — folding by
        // `Tombstone.merged(with:)` is what makes two peers resolve one deletion
        // identically.
        #expect(try await store.tombstones(since: nil) == [later])
    }

    // MARK: - Applying a plan

    /// The protocol promises a plan is idempotent, because it is only atomic per
    /// batch: a plan that throws part-way is re-derived and re-applied, and that
    /// has to reach the same place.
    @Test("Applying the same plan twice changes nothing the second time", arguments: Engine.all)
    func aPlanIsIdempotent(engine: Engine) async throws {
        let store = try await engine.make()
        let meta = Self.meta("shared", bytes: Data("shared".utf8))
        let pin = LWWRegister(value: true, timestamp: Self.epoch, deviceID: Self.device)
        let plan: [MergeAction] = [
            .insert(meta),
            .applyPin(contentHash: meta.contentHash, register: pin),
        ]

        try await store.applyRemote(plan)
        let once = try await store.syncIndex(since: nil)
        try await store.applyRemote(plan)
        #expect(try await store.syncIndex(since: nil) == once)
        #expect(once.first?.isPinned.value == true)
    }

    @Test("A plan can delete content and record why", arguments: Engine.all)
    func aPlanDeletesAndRecords(engine: Engine) async throws {
        let store = try await engine.make()
        let meta = Self.meta("doomed", bytes: Data("doomed".utf8))
        try await store.capture(meta, payloads: [Self.key: Data("doomed".utf8)])

        let tombstone = Tombstone(
            contentHash: meta.contentHash,
            deletedAt: Self.epoch.addingTimeInterval(120),
            deviceID: Self.device
        )
        try await store.applyRemote([
            .deleteLocally(contentHash: meta.contentHash),
            .recordTombstone(tombstone),
        ])

        #expect(try await store.syncIndex(since: nil).isEmpty)
        #expect(try await store.payload(for: meta.contentHash, key: Self.key) == nil)
        #expect(try await store.tombstones(since: nil) == [tombstone])
    }

    /// Expiry is applied by `MergeEngine` against its own clock, and a store
    /// that ignored the drop would read the same expired rows into every later
    /// merge only to discard them again.
    @Test("A plan can drop a tombstone the merge no longer honours", arguments: Engine.all)
    func aPlanDropsAnExpiredTombstone(engine: Engine) async throws {
        let store = try await engine.make()
        let hash = String(repeating: "c", count: 64)
        try await store.recordTombstone(
            Tombstone(contentHash: hash, deletedAt: Self.epoch, deviceID: Self.device)
        )
        try await store.applyRemote([.dropTombstone(contentHash: hash)])
        #expect(try await store.tombstones(since: nil).isEmpty)
    }

    // MARK: - Fixtures

    static func meta(
        _ text: String,
        bytes: Data,
        isConcealed: Bool = false,
        at createdAt: Date = epoch
    ) -> SyncClipMeta {
        SyncClipMeta(
            contentHash: ProbeContentHash.text(text),
            kind: "text",
            preview: text,
            createdAt: createdAt,
            isPinned: LWWRegister(value: false, timestamp: createdAt, deviceID: device),
            isConcealed: isConcealed,
            originDeviceID: device,
            representations: bytes.isEmpty
                ? []
                : [RepresentationDescriptor(key: key, byteCount: bytes.count)]
        )
    }
}

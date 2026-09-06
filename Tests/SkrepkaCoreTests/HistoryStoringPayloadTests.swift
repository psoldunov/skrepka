import Foundation
import SkrepkaSync
import Testing

@testable import SkrepkaCore

/// The lazy half of design §7: a row learned from a peer arrives with metadata
/// and no bytes, and the transport fills it in afterwards.
///
/// Split from `HistoryStoringSyncTests.swift` because filling a row is its own
/// question with its own failure modes — arriving in instalments, arriving for
/// content this machine captured itself — and because the two engines have
/// disagreed about it. Still an extension on the same suite, so a divergence
/// fails the one suite a reader is already watching.
extension HistoryStoringTests {
    // MARK: - Filling in a learned row
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

    /// **A fetch that arrives in instalments must land all of them**, and both
    /// engines have to agree that it does.
    ///
    /// `SyncExchange` fetches one item's missing representations together, but it
    /// can come back with only some: its per-round budget runs out mid-item, or
    /// the peer answers an empty final chunk for a representation it no longer
    /// holds. The rest arrives on a later round.
    ///
    /// The SwiftData engine used to guard the whole row — `payloadData.isEmpty` —
    /// so once anything had landed, everything after it was dropped while the
    /// stored index went on reporting it missing. That is a fetch repeated every
    /// `PeerLink.resyncInterval` forever, for bytes that never land. The SQLite
    /// engine guarded per representation and did not have it, which is the worse
    /// half: two engines disagreeing about the same question.
    @Test(
        "Representations that arrive in separate fetches all land",
        arguments: HistoryStoreEngine.all
    )
    func captureFillsRepresentationsAcrossFetches(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        let meta = EngineFixtures.twoRepresentationMeta("in pieces")
        let plain = Data("plain".utf8)
        let rich = Data("rich".utf8)

        // Learned from a peer with no bytes at all, then filled one at a time.
        try await store.capture(meta, payloads: [:])
        try await store.capture(meta, payloads: [EngineFixtures.plainTextKey: plain])
        try await store.capture(meta, payloads: [EngineFixtures.richTextKey: rich])

        #expect(try await store.summaries().count == 1)
        #expect(try await store.payload(for: meta.contentHash, key: EngineFixtures.plainTextKey) == plain)
        #expect(try await store.payload(for: meta.contentHash, key: EngineFixtures.richTextKey) == rich)
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
}

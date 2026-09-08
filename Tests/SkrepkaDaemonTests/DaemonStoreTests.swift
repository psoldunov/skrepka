import Foundation
import SkrepkaCore
import SkrepkaIPC
import SkrepkaSync
import Testing

@testable import SkrepkaDaemon

/// The store read the daemon's D-Bus interface is built on, and how a client's
/// selector resolves against it.
@Suite("Daemon store reads")
struct DaemonStoreTests {
    static func item(_ text: String, pinned: Bool = false, createdAt: Date) -> ClipItem {
        ClipItem(
            kind: .text,
            text: text,
            payload: ClipPayload(representations: ["public.utf8-plain-text": Data(text.utf8)]),
            sourceBundleID: nil,
            createdAt: createdAt,
            isPinned: pinned
        )
    }

    /// Recent timestamps, not fixed ones.
    ///
    /// `capture` applies the retention policy, whose default caps an unpinned
    /// entry's age — so a fixture dated to a literal `timeIntervalSince1970` is
    /// evicted the moment it is written, and every assertion below runs against
    /// an empty store while `capture` still answers `true`. Learned the hard
    /// way; anchored to `now` so it cannot come back.
    static func store(_ texts: [(String, Bool)]) async throws -> SQLiteHistoryStore {
        let store = try SQLiteHistoryStore(location: nil)
        let base = Date()
        for (offset, entry) in texts.enumerated() {
            _ = await store.capture(
                Self.item(
                    entry.0,
                    pinned: entry.1,
                    createdAt: base.addingTimeInterval(TimeInterval(offset))
                )
            )
        }
        return store
    }

    @Test("the listing carries the content hash and the representation types")
    func listingCarriesWhatAClientNeeds() async throws {
        let store = try await Self.store([("hello", false)])
        let listing = try await store.listing()
        let entry = try #require(listing.first)
        // Without the hash a client cannot name an entry across a change to the
        // list, which is the whole reason `ClipSummary` was not enough.
        #expect(entry.contentHash.count == 64)
        #expect(entry.representationTypes == ["public.utf8-plain-text"])
        #expect(entry.summary.text == "hello")
    }

    @Test("the listing is newest first with pinned entries hoisted")
    func listingUsesTheSameProjectionThePickerDoes() async throws {
        let store = try await Self.store([("first", false), ("second", true), ("third", false)])
        let listing = try await store.listing()
        // The same `ClipProjection` order `summaries()` produces. A daemon and
        // a picker showing different orders for one history is the drift that
        // projection exists to prevent, so this asserts they agree rather than
        // asserting a hard-coded order.
        let summaries = try await store.summaries()
        // Asserted non-empty first: two empty lists are equal, and a fixture
        // that silently stored nothing would pass this comparison forever.
        #expect(listing.count == 3)
        #expect(listing.map(\.summary.id) == summaries.map(\.id))
        #expect(listing.first?.summary.text == "second")
    }

    @Test("a position selector is one-based against the list as printed")
    func resolvesByPosition() async throws {
        let store = try await Self.store([("a", false), ("b", false)])
        let listing = try await store.listing()
        #expect(Daemon.resolve(ClipSelector("1"), in: listing)?.summary.text == "b")
        #expect(Daemon.resolve(ClipSelector("2"), in: listing)?.summary.text == "a")
        #expect(Daemon.resolve(ClipSelector("0"), in: listing) == nil)
        #expect(Daemon.resolve(ClipSelector("3"), in: listing) == nil)
    }

    @Test("a hash prefix resolves, and an ambiguous one resolves to nothing")
    func resolvesByHash() async throws {
        let store = try await Self.store([("a", false), ("b", false)])
        let listing = try await store.listing()
        let hash = try #require(listing.first?.contentHash)
        #expect(Daemon.resolve(ClipSelector(hash), in: listing)?.contentHash == hash)
        #expect(Daemon.resolve(ClipSelector(String(hash.prefix(12))), in: listing)?.contentHash == hash)
        // The empty prefix matches everything, which is exactly the ambiguous
        // case: picking either entry pastes something nobody asked for.
        #expect(Daemon.resolve(ClipSelector("zz"), in: listing) == nil)
    }

    @Test("an ambiguous prefix is refused rather than guessed")
    func refusesAnAmbiguousPrefix() async throws {
        let store = try await Self.store([("a", false), ("b", false)])
        let listing = try await store.listing()
        // Both hashes share the empty prefix. `identifier(forContentHashPrefix:)`
        // throws rather than returning either.
        #expect(listing.count == 2)
        await #expect(throws: SQLiteHistoryStore.ListingError.self) {
            _ = try await store.identifier(forContentHashPrefix: "")
        }
    }

    @Test("a clip document reports canonical media types, not pasteboard identifiers")
    func documentsUseCanonicalTypes() async throws {
        let store = try await Self.store([("hello", false)])
        let listing = try await store.listing()
        let document = Daemon.clipDocument(try #require(listing.first))
        // `public.utf8-plain-text` is a macOS identifier and has no business
        // crossing a bus to a JavaScript client.
        #expect(document.representations == ["text/plain;charset=utf-8"])
        #expect(document.kind == "text")
        #expect(document.contentHash.count == 64)
    }

    @Test("a multi-line preview is flattened once, in the daemon")
    func flattensThePreview() async throws {
        let store = try SQLiteHistoryStore(location: nil)
        _ = await store.capture(Self.item("one\ntwo\nthree", createdAt: Date()))
        let document = Daemon.clipDocument(try #require(try await store.listing().first))
        // Flattened here so a GNOME menu and `skrepka list` render the same
        // string rather than each inventing its own truncation.
        #expect(document.preview == "one two three")
    }
}

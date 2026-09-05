import Foundation
import Testing

@testable import SkrepkaCore

@Suite("Search")
struct MatcherTests {
    private func summary(_ text: String, pinned: Bool = false, concealed: Bool = false) -> ClipSummary {
        ClipSummary(
            id: UUID(),
            kind: .text,
            text: text,
            sourceBundleID: nil,
            createdAt: Date(),
            isPinned: pinned,
            isConcealed: concealed,
            imageSize: nil,
            byteCount: nil,
            thumbnail: nil
        )
    }

    @Test("An empty query preserves store order")
    func emptyQueryIsIdentity() {
        let items = [summary("one"), summary("two")]
        #expect(Matcher().filter(items, query: "   ").map(\.text) == ["one", "two"])
    }

    @Test("Non-matching entries are filtered out")
    func filtersNonMatches() {
        let items = [summary("hello world"), summary("goodbye")]
        #expect(Matcher().filter(items, query: "hello").map(\.text) == ["hello world"])
    }

    @Test("Matching is case- and diacritic-insensitive")
    func matchesLoosely() {
        let items = [summary("Café Society")]
        #expect(Matcher().filter(items, query: "cafe").count == 1)
        #expect(Matcher().filter(items, query: "SOCIETY").count == 1)
    }

    @Test("A prefix match outranks a mid-word match")
    func prefixWins() {
        let items = [summary("unhelpful help"), summary("help me")]
        #expect(Matcher().filter(items, query: "help").first?.text == "help me")
    }

    @Test("A tighter match outranks the same word buried in an essay")
    func coverageWins() {
        let long = String(repeating: "padding ", count: 40) + "swift"
        let items = [summary(long), summary("swift")]
        #expect(Matcher().filter(items, query: "swift").first?.text == "swift")
    }

    @Test("Concealed entries never match — searching must not confirm a secret is held")
    func concealedNeverMatches() {
        let items = [summary("hunter2", concealed: true)]
        #expect(Matcher().filter(items, query: "hunter2").isEmpty)
        #expect(Matcher.score(items[0], query: "hunter2") == nil)
    }

    @Test("Pinned entries break ties in their favour")
    func pinnedBreaksTies() {
        let items = [summary("target"), summary("target", pinned: true)]
        #expect(Matcher().filter(items, query: "target").first?.isPinned == true)
    }
}

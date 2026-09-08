import Foundation
import Testing

@testable import SkrepkaDaemon

/// What every client is handed, and why it is handed it by the daemon.
///
/// A clip holding `ESC ] 0 ; … BEL` retitles the terminal of whoever runs
/// `skrepka list`; a peer's advertised name is worse, because it is chosen by
/// whoever is on the LAN. Doing this once in the daemon is what stops the
/// Phase 8 GNOME extension having to rediscover it.
@Suite("Text handed to a client")
struct SafeTextTests {
    @Test("an escape sequence does not survive")
    func stripsEscapeSequences() {
        // The two that matter: a window-title sequence, and erase-display.
        #expect(SafeText.oneLine("a\u{1B}]0;pwned\u{07}b") == "a]0;pwnedb")
        #expect(SafeText.oneLine("a\u{1B}[2Jb") == "a[2Jb")
    }

    @Test("C0, DEL and C1 all go; tab and space stay")
    func stripsEveryControlRange() {
        #expect(SafeText.oneLine("a\u{00}\u{01}\u{1F}b") == "ab")
        #expect(SafeText.oneLine("a\u{7F}b") == "ab")
        #expect(SafeText.oneLine("a\u{80}\u{9F}b") == "ab")
        #expect(SafeText.oneLine("a\tb c") == "a\tb c")
    }

    @Test("a line break becomes a space, so the row stays one line")
    func flattensLineBreaks() {
        #expect(SafeText.oneLine("one\ntwo\r\nthree") == "one two three")
        #expect(SafeText.oneLine("a\u{2028}b\u{0085}c") == "a b c")
    }

    /// `ClipSummary.text` is the whole clipboard text, bounded only by the
    /// 32 MB capture ceiling — so one row could be megabytes on a single line.
    @Test("a long value is cut, and marked as cut")
    func truncates() {
        #expect(SafeText.oneLine(String(repeating: "x", count: 4), limit: 4) == "xxxx")
        // The ellipsis is inside the budget, not added to it: a column sized
        // on the limit cannot be handed one character more than it asked for.
        #expect(SafeText.oneLine(String(repeating: "x", count: 5), limit: 4) == "xxx…")
        #expect(SafeText.oneLine(String(repeating: "x", count: 4096)).count == SafeText.previewLimit)
    }

    /// The shape that caught the off-by-one: `limit` printable characters and
    /// then something at the end. A trailing character that is dropped is not
    /// a truncation and must not be marked as one, and a trailing line break
    /// — the ordinary shape of copied text — must still fit the budget.
    @Test("a value that ends at the limit is not over it")
    func truncatesAtTheBoundary() {
        #expect(SafeText.oneLine("xxxx\u{00}", limit: 4) == "xxxx")
        #expect(SafeText.oneLine("xxxx\u{1B}", limit: 4) == "xxxx")
        #expect(SafeText.oneLine("xxxx\n", limit: 4).count == 4)
    }

    /// A cut inside a grapheme cluster produces something no terminal renders
    /// as the character the user copied.
    @Test("the cut lands on a character boundary")
    func truncatesWholeCharacters() {
        // Three clusters into a budget of two: one cluster, then the ellipsis
        // in the second slot. Whole clusters either way — never half of one.
        let family = "👩‍👩‍👧‍👦"
        #expect(SafeText.oneLine(family + family + family, limit: 2) == family + "…")
        #expect(SafeText.oneLine("ééé", limit: 2) == "é…")
    }

    @Test("an absent value stays absent")
    func passesNilThrough() {
        #expect(SafeText.oneLine(ifPresent: nil) == nil)
        #expect(SafeText.oneLine(ifPresent: "a\u{1B}b", limit: SafeText.nameLimit) == "ab")
    }
}

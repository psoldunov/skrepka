import Foundation

/// One line of printable text, for anything the daemon hands a client.
///
/// ## Why this is in the daemon and not in the CLI
///
/// Every client gets it this way — `skrepka list`, the Phase 8 GNOME Shell
/// extension, and whatever calls the bus next — instead of each one
/// rediscovering the problem. A fix in one client is a fix nobody else has.
///
/// ## What the problem is
///
/// Flattening a preview by splitting on newlines removes U+000A–U+000D, U+0085
/// and the two separator characters, and nothing else. ESC survives, so a clip
/// holding `\u{1B}]0;…\u{07}` retitles the terminal of whoever runs `skrepka
/// list`, and `\u{1B}[2J` clears their screen. A peer's advertised name is the
/// more serious half of this, because it is chosen by whoever is on the LAN
/// rather than by whoever used this machine's clipboard.
///
/// Length is the other half: `ClipSummary.text` is the whole clipboard text,
/// bounded only by `defaultMaximumItemBytes` — 32 MB — so one row could be
/// megabytes on a single unwrapped line.
enum SafeText {
    /// How much of a clip's preview a client is given.
    static let previewLimit = 512

    /// How much of a name is. Shorter, because a name goes in a column.
    static let nameLimit = 64

    /// Marks a value that was cut short.
    static let ellipsis: Character = "…"

    /// `text` as one line of printable characters, never longer than `limit`.
    ///
    /// Truncated on a `Character` rather than a scalar or a byte, so no
    /// grapheme cluster is split in half — an emoji or a combining sequence
    /// arrives whole or not at all.
    ///
    /// The ellipsis is inside the budget rather than added to it, so a caller
    /// that sized a column on ``nameLimit`` cannot be handed one character
    /// more than it asked for. And the budget is spent only on a character
    /// that is actually kept: checking before ``rendered(_:)`` marked a value
    /// as cut short because of trailing characters that were dropped anyway.
    static func oneLine(_ text: String, limit: Int = previewLimit) -> String {
        guard limit > 0 else { return "" }
        var line = ""
        var length = 0
        for character in text {
            guard let kept = rendered(character) else { continue }
            guard length < limit else { return String(line.dropLast()) + String(ellipsis) }
            line.append(kept)
            length += 1
        }
        return line
    }

    /// ``oneLine(_:limit:)`` for a value that may be absent, which is the shape
    /// `PeerDocument.name` wants.
    ///
    /// Labelled rather than a second `oneLine(_:)`, because two overloads
    /// differing only in the optionality of one parameter are ambiguous at
    /// every call site that passes a non-optional: `String` converts implicitly
    /// to `String?`, so both candidates match and neither is more specific.
    static func oneLine(ifPresent text: String?, limit: Int = previewLimit) -> String? {
        text.map { oneLine($0, limit: limit) }
    }

    /// What one character becomes: a space for a line break, nothing for a
    /// control character, itself otherwise.
    ///
    /// Dropped are C0 (U+0000–U+001F), DEL (U+007F) and C1 (U+0080–U+009F).
    /// Tab is kept — it is inside C0 but it is ordinary text, and a terminal
    /// does nothing with it a space would not.
    private static func rendered(_ character: Character) -> Character? {
        if character.isNewline { return " " }
        if character == "\t" { return character }
        guard !character.unicodeScalars.contains(where: isControl) else { return nil }
        return character
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F, 0x80...0x9F: true
        default: false
        }
    }
}

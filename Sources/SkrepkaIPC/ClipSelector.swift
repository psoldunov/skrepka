import Foundation

/// How a client names one history entry.
///
/// Two spellings, because the two callers are different. A person typing
/// `skrepka copy 3` has a numbered list in front of them; a GNOME menu item
/// holds the hash it was built from and must not be re-numbered by whatever
/// arrived since it was drawn.
///
/// **The position is deliberately fragile and the hash deliberately is not.**
/// `skrepka copy 3` resolves against the list as it stands at the moment of the
/// call, which is what someone reading a terminal expects; a menu that stored a
/// position would paste the wrong thing the first time a copy happened while
/// the menu was open.
public enum ClipSelector: Sendable, Hashable {
    /// One-based, against the same order ``HistoryDocument/clips`` is in.
    /// One-based because that is what the list printed.
    ///
    /// Zero is the one out-of-band value: ``init(_:)`` uses it for text that
    /// names nothing, so a selector arriving off the wire always resolves to
    /// "no such entry" rather than to the wrong entry.
    case position(Int)

    /// A `contentHash`, or any unambiguous prefix of one. A prefix that matches
    /// more than one entry is an error rather than a guess — the entries a
    /// short prefix collides on are unrelated content, and picking either is
    /// pasting something the user did not ask for.
    case hash(String)

    /// The wire spelling, for a caller that has nowhere to report a bad one.
    ///
    /// Text that names nothing — `""`, `"0"`, `"-1"` — becomes
    /// ``position(_:)`` zero, which resolves to nothing. It must not fall
    /// through to a hash prefix: `"0"` prefix-matches every hash beginning with
    /// a zero, so `copy 0` would put back an entry nobody chose. Anything that
    /// can report the problem should use ``init(validating:)`` instead.
    public init(_ text: String) {
        self = ClipSelector(validating: text) ?? .position(0)
    }

    /// The wire spelling, rejecting one that names nothing: digits are a
    /// position, anything else is a hash prefix, and the empty string and a
    /// non-positive integer are neither.
    ///
    /// Unambiguous despite looking like it should not be. A `contentHash` is
    /// 64 lowercase hex characters, and a prefix short enough to be all digits
    /// and also parse as an `Int` is at most 19 characters of `0`–`9` — which
    /// would be a prefix so weak it collides on almost anything. The rule is
    /// therefore "if it parses as a positive integer it is a position", and a
    /// caller holding a full hash never lands there. `"0a1b"` does not parse as
    /// an integer at all, so it stays a hash prefix.
    public init?(validating text: String) {
        guard !text.isEmpty else { return nil }
        if let position = Int(text) {
            guard position > 0 else { return nil }
            self = .position(position)
        } else {
            self = .hash(text.lowercased())
        }
    }

    public var wireValue: String {
        switch self {
        case .position(let index): String(index)
        case .hash(let hash): hash
        }
    }
}

import Foundation

/// The two spellings of "these files are on the clipboard" that Linux uses.
///
/// `text/uri-list` is RFC 2483: one URI per line, CRLF-separated, and lines
/// beginning `#` are comments. `x-special/gnome-copied-files` is Nautilus's
/// own, undocumented by its authors' own admission, and is a verb line followed
/// by the same URIs.
///
/// One parser for both, because the difference is a single leading line and two
/// parsers is how they drift. Formatting is likewise one function with the verb
/// as a parameter.
enum URIList {
    /// GNOME's cut-versus-copy verb, which has no macOS equivalent (design §8).
    /// Skrepka only ever copies.
    static let copyVerb = "copy"

    /// The file URLs a body names, in the order it named them.
    ///
    /// Verified 2026-09-07 against `src/nautilus-clipboard.c` in Nautilus:
    /// the verb is written first, then `\n` is appended *before* each URI, so a
    /// well-formed body has no trailing newline and no terminating NUL. Both
    /// are tolerated anyway — Thunar, Nemo and Dolphin all write this target,
    /// the format has no specification to appeal to, and a stray byte at the
    /// end is not worth losing the whole copy over.
    ///
    /// Anything that is not a parseable `file:` URL is skipped rather than
    /// guessed at, for the reason `PasteboardReader.fileURLs(in:)` skips one:
    /// any application may put anything under this target, and a row claiming a
    /// file it has not got pastes nothing.
    static func parse(_ data: Data) -> [URL] {
        guard var text = String(data: data, encoding: .utf8) else { return [] }
        // A NUL terminator, if some producer added one, is not part of any line.
        if let terminator = text.firstIndex(of: "\0") { text = String(text[..<terminator]) }
        return
            text
            // RFC 2483 says CRLF; Nautilus writes bare LF. Split on both.
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap { line in
                guard let url = URL(string: line), url.isFileURL else { return nil }
                return url
            }
    }

    /// A `text/uri-list` body: the URIs, one per line, CRLF as RFC 2483 asks.
    static func formatURIList(_ urls: [URL]) -> Data {
        Data(urls.map(\.absoluteString).joined(separator: "\r\n").utf8)
    }

    /// An `x-special/gnome-copied-files` body: the verb, then the URIs.
    ///
    /// Bare LF and no trailing newline, matching what Nautilus itself writes —
    /// this target has no specification, so the only defensible framing is the
    /// one its author emits.
    static func formatGNOMECopiedFiles(_ urls: [URL]) -> Data {
        Data(([copyVerb] + urls.map(\.absoluteString)).joined(separator: "\n").utf8)
    }
}

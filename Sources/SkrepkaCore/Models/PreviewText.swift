import Foundation

/// The single-line rendering a history row shows, shared by ``ClipItem`` and
/// ``ClipSummary``.
///
/// Both types need it and their fallbacks differ — an item falls back to its
/// raw text, a summary to the entry's dimensions or kind. Only the collapse
/// itself is common, so only the collapse lives here; duplicating it once
/// already let the mask and the whitespace rules drift apart.
enum PreviewText {
    /// Shown in place of anything a password manager marked concealed.
    static let concealedMask = "••••••••"

    /// Newlines collapsed to single spaces and blank lines dropped, or nil when
    /// nothing survives — the caller decides what to show instead.
    static func collapsed(_ text: String) -> String? {
        let joined = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }
}

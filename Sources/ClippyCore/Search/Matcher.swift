import Foundation

/// Ranked substring matching over the history.
///
/// Deliberately simple and in-memory: the picker filters a few hundred rows on
/// every keystroke, and a scan of that is far below the frame budget. If the
/// history grows to where this shows, the fix is FTS in the store, not a
/// cleverer scorer here.
public struct Matcher: Sendable {
    public init() {}

    /// Entries matching `query`, best first. An empty query preserves the
    /// store's own order, which already hoists pinned entries.
    public func filter(_ items: [ClipSummary], query: String) -> [ClipSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }

        return
            items
            .compactMap { item -> (item: ClipSummary, score: Int)? in
                guard let score = Self.score(item, query: trimmed) else { return nil }
                return (item, score)
            }
            .sorted { left, right in
                if left.score != right.score { return left.score > right.score }
                if left.item.isPinned != right.item.isPinned { return left.item.isPinned }
                return left.item.createdAt > right.item.createdAt
            }
            .map(\.item)
    }

    /// Higher is better; nil means no match.
    ///
    /// Concealed entries never match — searching for a password should not
    /// confirm that Clippy holds it.
    static func score(_ item: ClipSummary, query: String) -> Int? {
        guard !item.isConcealed else { return nil }

        let haystack = item.text
        guard
            let range = haystack.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive]
            )
        else { return nil }

        var score = 100
        if range.lowerBound == haystack.startIndex {
            score += 50
        } else if haystack[..<range.lowerBound].last?.isWhitespace == true {
            score += 25
        }
        // Prefer a match that covers more of the entry over one buried in an essay.
        let coverage = Double(query.count) / Double(max(haystack.count, 1))
        score += Int(coverage * 40)
        if item.isPinned { score += 10 }
        return score
    }
}

import Foundation

/// Shared limits for what a copied *selection* is allowed to cost.
///
/// One copied file costs one `resourceValues` call; a hundred cost a hundred,
/// and "select all, copy" is a thing people do. Both questions the detail pass
/// asks about a selection — what these files are, and how much they weigh — walk
/// the same list, so both are bounded by the same budget rather than each
/// inventing one.
///
/// The files themselves are never capped. A row that pasted fewer files than it
/// says it holds is the defect all of this exists to fix, so what gets bounded
/// is the work, never the list.
enum FileSelection {
    /// How long the whole selection may be interrogated for.
    ///
    /// Matched to ``DirectorySize/deadline``, which bounds the comparable walk
    /// inside a single copied folder: what either buys is that an enormous copy
    /// stops quickly. It runs on ``ThumbnailRenderer``, so what the budget
    /// protects is how soon the new row appears, not the interface.
    static let deadline: Duration = .milliseconds(250)

    /// How many of a selection's file names a row's text lists.
    ///
    /// The names are what the row draws and what search matches on, and both
    /// costs are paid over and over: ``ClipSummary/previewText`` re-joins the
    /// whole list every time the row is drawn, and the matcher scans it on every
    /// keystroke. A row is one truncated line, so past a hundred names nothing
    /// further is ever read.
    ///
    /// The trade-off is search, and it is worth stating plainly: the name of the
    /// five-hundredth file in a copy of two thousand will not match, and that
    /// copy still pastes all two thousand files. Only the naming is bounded —
    /// ``ClipSummary/fileCount`` counts stored URLs, so the count the row shows
    /// stays exact however many names went unlisted.
    static let maximumNamedFiles = 100

    /// How many of a selection's files the row draws in its stack.
    ///
    /// Three, because that is what a pile reads as: two says "a pair", four
    /// crowds a 48-point tile into mush, and past three the layers behind are
    /// hidden by the ones in front anyway. The exact number of files is on the
    /// badge and in the subtitle, so the stack has only to say "several".
    ///
    /// Each one is an icon read off disk and a picture stored on the row, so
    /// this bounds real work as well as the drawing.
    static let maximumStackedIcons = 3
}

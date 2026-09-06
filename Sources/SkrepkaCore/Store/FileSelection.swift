import Foundation

/// Shared limits for what a copied *selection* is allowed to cost.
///
/// One copied file costs one `resourceValues` call; a hundred cost a hundred,
/// and "select all, copy" is a thing people do. The detail pass makes two walks
/// of that list — ``CopiedSelection/look(at:deadline:)`` asking what these files
/// are, then ``ContentSize/byteCount(of:deadline:)`` asking what they weigh —
/// and ``deadline`` bounds each of them whole, so neither pass grows with the
/// number of files copied. Bounded work, not bounded wall clock: a single
/// syscall against a hung mount blocks until the mount gives up, which is the
/// caveat ``DirectorySize`` states and the reason both passes run on
/// ``ThumbnailRenderer``.
///
/// Not one budget across both. Two, because the stat walk has to finish before
/// there is anything to measure, and a sizing pass handed whatever the first
/// walk left over would report a size for a small copy and nothing for a large
/// one depending on how busy the volume was that second. What matters is that
/// neither walk scales with the file count, and neither does.
///
/// The files themselves are never capped. A row that pasted fewer files than it
/// says it holds is the defect all of this exists to fix, so what gets bounded
/// is the work, never the list.
enum FileSelection {
    /// How long one whole pass over the selection may take.
    ///
    /// Matched to ``DirectorySize/deadline``, which bounds the comparable walk
    /// inside a single copied folder: what either buys is that an enormous copy
    /// stops quickly. A selection of folders is both at once — every entry is a
    /// directory walk — so ``ContentSize`` spends this budget *down* across them
    /// rather than granting each a fresh ``DirectorySize/deadline``, which is
    /// what made a copy of twenty folders cost five seconds.
    ///
    /// It runs on ``ThumbnailRenderer``, so what the budget protects is how soon
    /// the new row appears, not the interface — and, because
    /// ``HistoryStore/capture(_:)`` awaits that actor, how soon the *next* copy
    /// can be stored.
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

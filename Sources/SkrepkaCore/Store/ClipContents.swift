import Foundation

/// Everything needed to put an entry back on the pasteboard.
///
/// Loaded only when something is actually pasted — see ``HistoryStore/items``
/// for why the list the picker draws carries neither of these parts.
public struct ClipContents: Sendable, Hashable {
    /// The first pasteboard item, as it was copied.
    public let payload: ClipPayload
    /// Every file the entry holds, the payload's own first.
    ///
    /// Empty for an entry that names no file, and for a file entry stored before
    /// Skrepka kept more than the first — that one pastes from its payload,
    /// exactly as it always did.
    public let fileURLs: [URL]

    public init(payload: ClipPayload, fileURLs: [URL]) {
        self.payload = payload
        self.fileURLs = fileURLs
    }

    /// The files that need a pasteboard item of their own: every one the payload
    /// is not already carrying.
    ///
    /// Matched by identity rather than by position, because the two can disagree.
    /// The payload is written once, at the capture that created the row, and
    /// never rewritten; ``fileURLs`` is replaced by every later copy that
    /// de-duplicates onto it — and a selection hashes the same whatever order it
    /// was clicked in, so the later copy may well lead with the other file.
    /// Dropping this list's *first* entry then wrote the payload's file twice and
    /// the other file never.
    ///
    /// A payload whose `public.file-url` bytes do not parse as one carries no
    /// file to exclude, so every file gets an item — the alternative is eating
    /// one of them to pay for a file that was never written.
    ///
    /// Excluded wherever it appears rather than at its first appearance.
    /// ``ClipItem`` keeps the list free of duplicates, so on the entries the
    /// store writes the two are the same thing; a row that somehow held one
    /// twice would otherwise put the payload's file on the pasteboard a second
    /// time, and Finder answers a file listed twice by copying it twice.
    public var additionalFileURLs: [URL] {
        guard let carried = payload.fileURL else { return fileURLs }
        return fileURLs.filter { $0 != carried }
    }
}

import Foundation

/// Tells a copied folder from a copied file, and a copied picture from both.
///
/// Finder puts the same thing on the pasteboard either way — one
/// `public.file-url` and nothing that says what is at the end of it — so every
/// copy off the Finder read "File", and a copied folder sat in the history
/// wearing a document icon next to the documents inside it. The file system is
/// the only thing that can answer.
///
/// Asking it is a blocking call against a volume that may be slow or gone, so
/// this sits here in `Store` beside ``ContentSize`` and ``ImageFileThumbnail``
/// rather than in the capture rules: everything that has to open the copied
/// thing runs together, once, on ``ThumbnailRenderer``. It takes a
/// ``CopiedFile`` rather than a `URL` for the same reason — one lookup answers
/// this and the size both.
enum FileURLKind {
    /// ``ClipKind/folder`` for a plain directory, ``ClipKind/imageFile`` for a
    /// file that declares itself a picture, and ``ClipKind/file`` for everything
    /// else.
    ///
    /// A picture earns its own kind so the row says "Image" rather than "File".
    /// The evidence is ``CopiedFile/isImage`` — the file's declared type, read
    /// in the same lookup as its shape. A file whose type is too vague to say —
    /// no extension, so `public.data` — stays a `.file` here and is upgraded by
    /// ``ThumbnailRenderer`` if it turns out to decode as a picture, which is
    /// the only evidence stronger than the type.
    ///
    /// A package is deliberately a file. `ChatGPT.app` and an `.rtfd` are
    /// directories on disk, but Finder presents each as one item and so does
    /// Skrepka: calling them folders would put a folder icon on every copied
    /// application, and would cost them their preview, since
    /// ``ClipKind/canPreview`` sends no folder to ``ThumbnailMaker``.
    ///
    /// Nil on ``CopiedFile/Shape/unknown``, and the caller reaches this with no
    /// ``CopiedFile`` at all for a path the file system would not describe —
    /// deleted since the copy, on an unmounted volume, behind a sandbox. "I
    /// could not look" and "I looked, and it is a file" are different answers,
    /// and collapsing them is what let a re-copy of an ejected folder overwrite
    /// a row that was already correctly labelled Folder. A caller with nothing
    /// stored yet treats nil as `.file`, which is what every entry recorded
    /// before folders were told apart already reads as; a caller holding an
    /// earlier answer keeps it.
    ///
    /// Guessing "folder" from a trailing slash instead would be a guess: the
    /// URL a `public.file-url` carries is written by whichever app did the
    /// copy, and nothing obliges it to mark directories.
    static func kind(of file: CopiedFile) -> ClipKind? {
        switch file.shape {
        case .folder: .folder
        case .package: .file
        case .file: file.isImage ? .imageFile : .file
        case .unknown: nil
        }
    }

    /// One kind for a whole selection: the kind they all share, or
    /// ``ClipKind/file`` when they disagree.
    ///
    /// A mixed selection has no honest single label — three pictures and a
    /// folder are four files — and `.file` is the one kind every entry here
    /// genuinely is.
    ///
    /// Nil when the walk did not finish, and nil when it finished having
    /// described nothing. Both are "I could not look", and neither may become
    /// `.file`: ``HistoryStore`` writes a refined kind onto a row it already has
    /// only when one came back, precisely so a re-copy that could not see the
    /// disk cannot overwrite a good label — and `.file` is an answer, so
    /// returning it would downgrade a row reading "300 Images" the first time
    /// that selection was re-copied off a cold or networked volume. A new row
    /// loses nothing: ``ClipRecordMapping/makeRecord(from:details:)`` falls back
    /// to the capture rules' own `.file`, which is what it would have shown.
    ///
    /// A selection where *some* file went missing is likewise unanswered, for
    /// the reason ``ContentSize`` gives about a partial sum: the two files left
    /// of three agreeing on `.imageFile` says nothing about the third.
    static func kind(of selection: CopiedSelection) -> ClipKind? {
        guard selection.isComplete else { return nil }

        var shared: ClipKind?
        for file in selection.files {
            guard let kind = kind(of: file) else { return nil }
            guard let current = shared else {
                shared = kind
                continue
            }
            if current != kind { return .file }
        }
        return shared
    }
}

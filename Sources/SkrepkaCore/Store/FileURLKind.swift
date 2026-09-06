import Foundation
import UniformTypeIdentifiers

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
/// thing runs together, once, on ``ThumbnailRenderer``.
enum FileURLKind {
    /// ``ClipKind/folder`` for a plain directory, ``ClipKind/imageFile`` for a
    /// file whose type is a picture, ``ClipKind/file`` for everything else, and
    /// nil when the file system would not answer.
    ///
    /// A picture earns its own kind so the row says "Image" rather than "File".
    /// The file's declared type answers that, not its bytes: `contentType` comes
    /// off the same `resourceValues` call the directory question already makes,
    /// so naming pictures costs no extra trip to disk. A file whose type is too
    /// vague to say — no extension, so `public.data` — stays a `.file` here and
    /// is upgraded by ``ThumbnailRenderer`` if it turns out to decode as a
    /// picture, which is the only evidence stronger than the type.
    ///
    /// A package is deliberately a file. `ChatGPT.app` and an `.rtfd` are
    /// directories on disk, but Finder presents each as one item and so does
    /// Skrepka: calling them folders would put a folder icon on every copied
    /// application, and would cost them their preview, since
    /// ``ClipKind/canPreview`` sends no folder to ``ThumbnailMaker``.
    ///
    /// Nil rather than `.file` for a path the file system will not describe —
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
    static func kind(ofFileAt url: URL) -> ClipKind? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .contentTypeKey]
        guard let values = try? url.resourceValues(forKeys: keys),
            let isDirectory = values.isDirectory
        else { return nil }
        if isDirectory && values.isPackage != true { return .folder }
        return values.contentType?.conforms(to: .image) == true ? .imageFile : .file
    }

    /// One kind for a whole selection: the kind they all share, or
    /// ``ClipKind/file`` when they disagree.
    ///
    /// A mixed selection has no honest single label — three pictures and a
    /// folder are four files — and `.file` is the one kind every entry here
    /// genuinely is. Nil only when the file system described none of them, which
    /// callers read as "no answer" rather than as "file".
    ///
    /// A selection too long to finish inside ``FileSelection/deadline`` is left
    /// unanswered rather than called `.file`, because nil is what "I could not
    /// look" has to mean here. ``HistoryStore`` writes a refined kind onto a row
    /// it already has only when one came back, precisely so a re-copy that could
    /// not see the disk cannot overwrite a good label — and `.file` is an answer,
    /// so returning it would downgrade a row reading "300 Images" the first time
    /// that selection was re-copied off a cold or networked volume. A new row
    /// loses nothing: ``ClipRecordMapping/makeRecord(from:details:)`` falls back
    /// to the capture rules' own `.file`, which is what it would have shown.
    static func kind(ofFilesAt urls: [URL], deadline: Duration = FileSelection.deadline) -> ClipKind? {
        let clock = ContinuousClock()
        let start = clock.now
        var shared: ClipKind?

        for url in urls {
            if clock.now - start > deadline { return nil }
            guard let kind = kind(ofFileAt: url) else { continue }
            guard let current = shared else {
                shared = kind
                continue
            }
            if current != kind { return .file }
        }
        return shared
    }
}

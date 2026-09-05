import Foundation

/// Tells a copied folder from a copied file.
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
    /// ``ClipKind/folder`` for a plain directory, ``ClipKind/file`` for
    /// everything else, and nil when the file system would not answer.
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
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
            let isDirectory = values.isDirectory
        else { return nil }
        return isDirectory && values.isPackage != true ? .folder : .file
    }
}

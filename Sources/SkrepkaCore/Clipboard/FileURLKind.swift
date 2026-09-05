import Foundation

/// Tells a copied folder from a copied file.
///
/// Finder puts the same thing on the pasteboard either way — one
/// `public.file-url` and nothing that says what is at the end of it — so every
/// copy off the Finder read "File", and a copied folder sat in the history
/// wearing a document icon next to the documents inside it. The file system is
/// the only thing that can answer.
enum FileURLKind {
    /// ``ClipKind/folder`` for a plain directory, ``ClipKind/file`` for
    /// everything else.
    ///
    /// A package is deliberately a file. `ChatGPT.app` and an `.rtfd` are
    /// directories on disk, but Finder presents each as one item and so does
    /// Skrepka: calling them folders would put a folder icon on every copied
    /// application, and would cost them their preview, since
    /// ``ClipKind/canPreview`` sends no folder to ``ThumbnailMaker``.
    ///
    /// A path the file system will not answer for — deleted since the copy, on
    /// an unmounted volume, behind a sandbox — is a file. It is the reading
    /// that was already there for every entry stored before this existed, and
    /// guessing "folder" from a trailing slash instead would be a guess: the
    /// URL a `public.file-url` carries is written by whichever app did the
    /// copy, and nothing obliges it to mark directories.
    static func kind(ofFileAt url: URL) -> ClipKind {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
            values.isDirectory == true,
            values.isPackage != true
        else { return .file }
        return .folder
    }
}

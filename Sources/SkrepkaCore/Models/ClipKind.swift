import Foundation

/// What a clipboard entry fundamentally is, chosen from the richest
/// representation the pasteboard offered.
public enum ClipKind: String, Codable, Sendable, CaseIterable {
    case text
    case richText
    case link
    case file
    case folder
    case image
    /// A picture that lives on disk, as opposed to ``image``, which carries its
    /// own bytes. Copying a screenshot in Finder produces this one.
    case imageFile

    /// SF Symbol used to badge the entry in the picker.
    public var symbolName: String {
        switch self {
        case .text: "text.alignleft"
        case .richText: "textformat"
        case .link: "link"
        case .file: "doc"
        case .folder: "folder"
        case .image, .imageFile: "photo"
        }
    }

    public var displayName: String {
        switch self {
        case .text: "Text"
        case .richText: "Rich Text"
        case .link: "Link"
        case .file: "File"
        case .folder: "Folder"
        case .image, .imageFile: "Image"
        }
    }

    /// The label for a row holding more than one of these — "3 Images".
    ///
    /// Only file-system kinds are ever counted, so the others fall back to the
    /// singular rather than inventing a plural nothing will ask for.
    public var pluralDisplayName: String {
        switch self {
        case .file: "Files"
        case .folder: "Folders"
        case .imageFile: "Images"
        case .text, .richText, .link, .image: displayName
        }
    }

    /// Whether the entry points at something on disk rather than carrying its
    /// own content.
    ///
    /// `.file`, `.folder` and `.imageFile` differ only in their icon and their
    /// label: all three arrive as a `public.file-url`, all three are labelled by
    /// their last path component, and all three hash on the URL rather than on
    /// that label.
    public var isFileSystemEntry: Bool {
        switch self {
        case .file, .folder, .imageFile: true
        case .text, .richText, .link, .image: false
        }
    }

    /// Whether an entry of this kind is worth asking ``ThumbnailMaker`` about.
    ///
    /// `.file` is on the list because a copied picture is a file, not an image:
    /// `public.file-url` outranks `public.png` in ``PasteboardType/readOrder``,
    /// so a screenshot copied out of Finder arrives here as `.file`. Excluding
    /// it is what left those rows showing a generic document icon. Files that
    /// turn out not to be images simply get no preview.
    ///
    /// `.folder` is not: a directory is never a picture, so opening it could
    /// only ever confirm that. An application bundle is a directory too, but it
    /// classifies as `.file` — see ``FileURLKind`` — so it keeps its preview.
    var canPreview: Bool {
        switch self {
        case .image, .file, .imageFile: true
        case .text, .richText, .link, .folder: false
        }
    }

    /// The kind as it enters ``ClipItem/contentHash``.
    ///
    /// Every file-system kind deliberately shares one. The file URL they hash on
    /// already identifies the thing uniquely, so the case adds nothing — and it
    /// must not be added, or the same folder would de-duplicate against itself
    /// only while the two captures happened to agree on which it was.
    ///
    /// Capture never produces `.folder` or `.imageFile` today: ``CaptureRules``
    /// calls every file URL a `.file` and ``ThumbnailRenderer`` refines it
    /// afterwards, so the hash sees `.file` either way. This keeps that from
    /// being load bearing. A ``ClipItem`` built directly as `.folder` — the
    /// store's own tests do it, and nothing stops a future caller — still lands
    /// on the row it duplicates rather than beside it.
    var hashDomain: String {
        isFileSystemEntry ? ClipKind.file.rawValue : rawValue
    }

    /// Representations that carry identity, richest first, for the kinds whose
    /// ``ClipItem/text`` cannot be trusted to.
    ///
    /// An image has no text at all, and a file's text is only its last path
    /// component — two files in different folders share one. `nil` means the
    /// text *is* the identity, which is what lets the same sentence copied out
    /// of two different apps collapse onto one entry.
    var identityTypes: [String]? {
        switch self {
        case .image: [PasteboardType.png, PasteboardType.tiff, PasteboardType.pdf]
        case .file, .folder, .imageFile: [PasteboardType.fileURL]
        case .text, .richText, .link: nil
        }
    }
}

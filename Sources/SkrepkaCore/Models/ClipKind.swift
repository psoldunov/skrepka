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

    /// SF Symbol used to badge the entry in the picker.
    public var symbolName: String {
        switch self {
        case .text: "text.alignleft"
        case .richText: "textformat"
        case .link: "link"
        case .file: "doc"
        case .folder: "folder"
        case .image: "photo"
        }
    }

    public var displayName: String {
        switch self {
        case .text: "Text"
        case .richText: "Rich Text"
        case .link: "Link"
        case .file: "File"
        case .folder: "Folder"
        case .image: "Image"
        }
    }

    /// Whether the entry points at something on disk rather than carrying its
    /// own content.
    ///
    /// `.file` and `.folder` differ only in their icon and their label: both
    /// arrive as a `public.file-url`, both are labelled by their last path
    /// component, and both hash on the URL rather than that label.
    public var isFileSystemEntry: Bool {
        self == .file || self == .folder
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
        case .image, .file: true
        case .text, .richText, .link, .folder: false
        }
    }

    /// The kind as it enters ``ClipItem/contentHash``.
    ///
    /// `.file` and `.folder` deliberately share one. The file URL they hash on
    /// already identifies the thing uniquely, so the case adds nothing — and it
    /// must not be added, or the same folder would de-duplicate against itself
    /// only while the two captures happened to agree on which it was.
    ///
    /// Capture never produces `.folder` today: ``CaptureRules`` calls every
    /// file URL a `.file` and ``ThumbnailRenderer`` refines it afterwards, so
    /// the hash sees `.file` either way. This keeps that from being load
    /// bearing. A ``ClipItem`` built directly as `.folder` — the store's own
    /// tests do it, and nothing stops a future caller — still lands on the row
    /// it duplicates rather than beside it.
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
        case .file, .folder: [PasteboardType.fileURL]
        case .text, .richText, .link: nil
        }
    }
}

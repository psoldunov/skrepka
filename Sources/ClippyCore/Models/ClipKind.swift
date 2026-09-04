import Foundation

/// What a clipboard entry fundamentally is, chosen from the richest
/// representation the pasteboard offered.
public enum ClipKind: String, Codable, Sendable, CaseIterable {
    case text
    case richText
    case link
    case file
    case image

    /// SF Symbol used to badge the entry in the picker.
    public var symbolName: String {
        switch self {
        case .text: "text.alignleft"
        case .richText: "textformat"
        case .link: "link"
        case .file: "doc"
        case .image: "photo"
        }
    }

    public var displayName: String {
        switch self {
        case .text: "Text"
        case .richText: "Rich Text"
        case .link: "Link"
        case .file: "File"
        case .image: "Image"
        }
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
        case .file: [PasteboardType.fileURL]
        case .text, .richText, .link: nil
        }
    }
}

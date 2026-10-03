import Foundation

/// A link's URL as plain text, for every link that would otherwise go without.
///
/// The field report: a link copied on an iPhone reached the Mac through
/// Universal Clipboard as a lone `public.url`, and the row recorded that and
/// nothing else. `RepresentationKeyMap` gives that type no wire form,
/// deliberately, so the row crossed to its peers holding no bytes at all, and
/// Linux, where no clipboard target carries a `public.url`, could not paste
/// it. The URL is already the row's text — see
/// ``CaptureRules/text(for:payload:fileURLs:)`` — so it travels as
/// `public.utf8-plain-text`, which every peer can paste.
///
/// Only links: a lone `public.url` is all a link needs to be one, and the map
/// names no wire form for it, so a link is the kind that can cross with
/// nothing to paste.
public enum LinkPlainText {
    /// `representations` with `text` added as plain text, when they belong to
    /// a link and carry none.
    ///
    /// What the pasteboard offered as plain text is kept: an app is entitled to
    /// put something other than the URL there, and it is what the user copied.
    public static func completing(
        _ representations: [String: Data],
        kind: ClipKind,
        text: String
    ) -> [String: Data] {
        guard kind == .link, representations[PasteboardType.string] == nil else {
            return representations
        }
        return representations.merging([PasteboardType.string: Data(text.utf8)]) { stored, _ in stored }
    }

    /// The same, for a row whose only copy of its text may be a capped
    /// preview — every row a peer sent.
    ///
    /// A peer sends at most 4 KB of a row's text (`SyncLimits.previewByteLimit`),
    /// and nothing here can tell a URL that fit from the front of one that did
    /// not; pasting the front opens the wrong page. A link's identity is its
    /// kind and its text, though, so a preview that hashes to the row's own
    /// identity is the whole text. Anything else is left as it was.
    ///
    /// This repairs rows that crossed before ``CaptureRules`` added the text at
    /// capture, and rows from a Mac running a build that predates it.
    public static func completing(
        _ representations: [String: Data],
        kind: ClipKind,
        preview: String,
        contentHash: String
    ) -> [String: Data] {
        guard kind == .link, representations[PasteboardType.string] == nil,
            isWhole(preview, ofLinkIdentifiedBy: contentHash)
        else { return representations }
        return completing(representations, kind: kind, text: preview)
    }

    /// Whether `preview` is the whole text of the link `contentHash` names.
    ///
    /// The payload is left out of the hash on purpose: a link hashes only its
    /// kind and text — see ``ClipItem/hash(kind:text:payload:fileURLs:)`` —
    /// so the bytes the row never received cannot change the answer.
    private static func isWhole(_ preview: String, ofLinkIdentifiedBy contentHash: String) -> Bool {
        let empty = ClipPayload(representations: [:])
        return ClipItem.hash(kind: .link, text: preview, payload: empty, fileURLs: []) == contentHash
    }
}

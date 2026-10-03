import Foundation
import Testing

@testable import SkrepkaCore

/// A link carries its URL as plain text wherever it goes.
///
/// The field report this pins: a link copied on an iPhone reached the Mac
/// through Universal Clipboard as a lone `public.url`. No sync representation
/// names that type, so the row reached Linux holding no bytes at all, and the
/// picker refused it with "nothing in that entry can be written to a Linux
/// clipboard".
@Suite("A link carries its URL as plain text")
struct LinkPlainTextTests {
    static let url =
        "https://www.inherence.dev/admin/intent/edit/id=a2f359826b8646c2bfe117236028a5f5;type=resource"

    /// What Universal Clipboard left on the Mac's pasteboard: the URL and
    /// nothing else.
    static let relayed = [PasteboardType.url: Data(url.utf8)]

    /// The identity the Mac gave that row, copied from both machines' stores.
    static let fieldHash = "4053b993622769695e2e10baedb7349e36fce4737f0673517cffb3fbbff4d060"

    private func capture(_ representations: [String: Data]) throws -> ClipItem {
        let snapshot = PasteboardSnapshot(
            representations: representations,
            declaredTypes: Array(representations.keys)
        )
        return try #require(CaptureRules().decide(snapshot).item)
    }

    @Test("a lone URL is captured with its plain text beside it")
    func relayedLinkGainsPlainText() throws {
        let item = try capture(Self.relayed)

        #expect(item.kind == .link)
        #expect(item.payload.data(forType: PasteboardType.string) == Data(Self.url.utf8))
        #expect(item.payload.data(forType: PasteboardType.url) == Data(Self.url.utf8))
    }

    @Test("the added text leaves the link's identity where it was")
    func identityIsUnchanged() throws {
        // A link hashes its kind and text, never its payload, so a row
        // captured before this change still collapses with one captured after.
        #expect(try capture(Self.relayed).contentHash == Self.fieldHash)
    }

    @Test("a link that brought its own text keeps it")
    func ownTextIsKept() throws {
        let own = Data("the app's own text".utf8)
        let item = try capture([PasteboardType.url: Data(Self.url.utf8), PasteboardType.string: own])

        #expect(item.payload.data(forType: PasteboardType.string) == own)
    }

    @Test("the ceiling holds for what is stored, text included")
    func addedTextCountsAgainstTheCeiling() {
        // The URL alone fits; the URL twice does not. Stored anyway, the row
        // would be one every peer refuses, because a peer's limit is this one.
        let urlBytes = Data(Self.url.utf8).count
        let snapshot = PasteboardSnapshot(
            representations: Self.relayed,
            declaredTypes: Array(Self.relayed.keys)
        )

        #expect(
            CaptureRules(maximumItemBytes: urlBytes).decide(snapshot)
                == .rejectedTooLarge(byteCount: 2 * urlBytes))
    }

    @Test("only links gain text")
    func otherKindsAreUntouched() {
        let picture = [PasteboardType.png: Data([0x89, 0x50, 0x4E, 0x47])]
        let markup = [PasteboardType.html: Data("<b>hi</b>".utf8)]

        #expect(LinkPlainText.completing(picture, kind: .image, text: "") == picture)
        #expect(LinkPlainText.completing(markup, kind: .richText, text: "hi") == markup)
    }

    @Test("a row that arrived with no bytes pastes its preview when the preview is the whole URL")
    func wholePreviewCompletesTheRow() {
        let completed = LinkPlainText.completing(
            [:], kind: .link, preview: Self.url, contentHash: Self.fieldHash)

        #expect(completed == [PasteboardType.string: Data(Self.url.utf8)])
    }

    @Test("a preview that is only the front of the URL is not pasted")
    func cappedPreviewIsRefused() {
        // A peer caps the preview at 4 KB. Pasting a prefix of a longer URL
        // would open the wrong page, which is worse than refusing.
        let prefix = String(Self.url.prefix(40))

        #expect(
            LinkPlainText.completing([:], kind: .link, preview: prefix, contentHash: Self.fieldHash)
                .isEmpty)
    }

    @Test("a row that already holds text is pasted as it is")
    func storedTextWins() {
        let stored = [PasteboardType.string: Data("stored".utf8)]

        #expect(
            LinkPlainText.completing(
                stored, kind: .link, preview: Self.url, contentHash: Self.fieldHash) == stored)
    }
}

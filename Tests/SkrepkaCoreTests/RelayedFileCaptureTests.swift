import Foundation
import Testing

@testable import SkrepkaCore
@testable import SkrepkaSync

/// A CleanShot screenshot copied on one Mac arrives on the other through
/// Universal Clipboard as a new file in a staging folder. Recording it there
/// made a second row for every screenshot, which sync carried back to the Mac
/// it was taken on — see `UniversalClipboardRelay`.
@Suite("Universal Clipboard relays at capture")
struct RelayedFileCaptureTests {
    /// Where a relayed screenshot sat on the receiving Mac, from a real history.
    private static let staged = URL(
        fileURLWithPath:
            "/Users/me/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/items/6E0E0FB1-07F4-4B58-A2BA-D793C68ECA07/CleanShot 2026-09-18 at 23.55.42@2x.png"
    )
    /// Where the same screenshot sat on the Mac it was taken on.
    private static let original = URL(
        fileURLWithPath:
            "/Users/me/Library/Application Support/CleanShot/media/media_lRtnrf6TKv/CleanShot 2026-09-18 at 23.55.42@2x.png"
    )
    private static let picture = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// What CleanShot puts on the pasteboard: the file, and the picture in it.
    private func screenshot(at files: [URL]) -> PasteboardSnapshot {
        let representations = [
            PasteboardType.fileURL: Data(files[0].absoluteString.utf8),
            PasteboardType.png: Self.picture,
        ]
        return PasteboardSnapshot(
            representations: representations,
            declaredTypes: Array(representations.keys),
            fileURLs: files
        )
    }

    @Test("A screenshot Universal Clipboard staged from another Mac is not recorded")
    func skipsAStagedScreenshot() {
        let decision = CaptureRules().decide(screenshot(at: [Self.staged]))
        #expect(decision == .rejectedUniversalClipboardRelay)
    }

    @Test("The same screenshot on the Mac it was taken on is recorded")
    func keepsTheOriginal() throws {
        let item = try #require(CaptureRules().decide(screenshot(at: [Self.original])).item)
        #expect(item.fileURLs == [Self.original])
    }

    /// Only a file carries a path to be relayed under. A picture or a sentence
    /// arrives as the same bytes it left as, and so as the same entry.
    @Test("A picture Universal Clipboard delivers without a file is recorded")
    func keepsAPictureWithoutAFile() throws {
        let snapshot = PasteboardSnapshot(
            representations: [PasteboardType.png: Self.picture],
            declaredTypes: [PasteboardType.png]
        )
        #expect(try #require(CaptureRules().decide(snapshot).item).kind == .image)
    }

    @Test("A selection holding one file of its own is recorded")
    func keepsAMixedSelection() throws {
        let item = try #require(CaptureRules().decide(screenshot(at: [Self.staged, Self.original])).item)
        #expect(item.fileURLs == [Self.staged, Self.original])
    }

    /// A relay over the size ceiling is still a relay. Reporting it as too
    /// large would log a notice about a copy nobody made on this Mac.
    @Test("A relay is named a relay whatever its size")
    func aLargeRelayIsStillARelay() {
        let rules = CaptureRules(maximumItemBytes: 4)
        #expect(rules.decide(screenshot(at: [Self.staged])) == .rejectedUniversalClipboardRelay)
    }

    /// Rich text outranks a file URL, so this is a rich-text entry hashed by its
    /// text, not a file hashed by its path. Only the second kind is a relay.
    @Test("Rich text that carries a staged file is recorded")
    func keepsRichTextBesideAStagedFile() throws {
        let representations = [
            PasteboardType.rtf: Data("{\\rtf1 hello}".utf8),
            PasteboardType.string: Data("hello".utf8),
            PasteboardType.fileURL: Data(Self.staged.absoluteString.utf8),
        ]
        let snapshot = PasteboardSnapshot(
            representations: representations,
            declaredTypes: Array(representations.keys),
            fileURLs: [Self.staged]
        )
        #expect(try #require(CaptureRules().decide(snapshot).item).kind == .richText)
    }

    /// `SkrepkaSync` cannot see ``ClipKind``, so it names the file kinds by raw
    /// value. A kind added to one side and not the other would have sync
    /// tombstone content capture keeps, or keep content capture refuses.
    @Test("Sync judges relays over the same kinds capture does")
    func syncNamesTheFileKinds() {
        let fileKinds = Set(ClipKind.allCases.filter(\.isFileSystemEntry).map(\.rawValue))
        #expect(UniversalClipboardRelay.fileSystemKinds == fileKinds)
    }

    @Test("A relay ends a hand-over, and is not worth a notice in the log")
    func aRelayIsAQuietRefusal() {
        #expect(CaptureDecision.rejectedUniversalClipboardRelay.isRefusedCopy)
        #expect(!CaptureDecision.rejectedUniversalClipboardRelay.isNoteworthyRejection)
        #expect(CaptureDecision.rejectedUniversalClipboardRelay.rejectionLogMessage != nil)
    }
}

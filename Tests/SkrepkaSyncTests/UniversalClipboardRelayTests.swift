import Foundation
import Testing

@testable import SkrepkaSync

@Suite("Universal Clipboard relays")
struct UniversalClipboardRelayTests {
    /// Where a relayed CleanShot screenshot sat on the Mac that received it,
    /// from a real two-Mac history on macOS 26.
    static let staged = URL(
        fileURLWithPath:
            "/Users/me/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/items/6E0E0FB1-07F4-4B58-A2BA-D793C68ECA07/CleanShot 2026-09-18 at 23.55.42@2x.png"
    )
    /// Where the same screenshot sat on the Mac it was taken on.
    static let original = URL(
        fileURLWithPath:
            "/Users/me/Library/Application Support/CleanShot/media/media_lRtnrf6TKv/CleanShot 2026-09-18 at 23.55.42@2x.png"
    )

    static let fileList = RepresentationKey(canonical: "text/uri-list", origin: "public.file-url")
    static let png = RepresentationKey(canonical: "image/png", origin: "public.png")

    // MARK: - Recognising a staged file

    @Test("A file in the staging folder is staged, whoever's home it is under")
    func recognisesTheStagingFolder() {
        #expect(UniversalClipboardRelay.isStaged(Self.staged))
        let elsewhere = URL(
            fileURLWithPath:
                "/Volumes/Home/deck/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/items/A/x.pdf"
        )
        #expect(UniversalClipboardRelay.isStaged(elsewhere))
    }

    @Test("A file anywhere else is not staged")
    func ignoresEverythingElse() throws {
        #expect(!UniversalClipboardRelay.isStaged(Self.original))
        // The folder itself is not a file staged in it.
        let folder = URL(
            fileURLWithPath:
                "/Users/me/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard",
            isDirectory: true
        )
        #expect(!UniversalClipboardRelay.isStaged(folder))
        // One matching component is not the folder.
        #expect(!UniversalClipboardRelay.isStaged(URL(fileURLWithPath: "/tmp/shared-pasteboard/x.png")))
        // The same path on a web server is not a file on this machine.
        let web = try #require(
            URL(
                string:
                    "https://example.com/Group%20Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/items/A/x.png"
            )
        )
        #expect(!UniversalClipboardRelay.isStaged(web))
    }

    @Test("A copy is a relay only when every file in it is staged")
    func judgesTheWholeSelection() {
        #expect(UniversalClipboardRelay.holdsOnlyStagedFiles([Self.staged]))
        #expect(!UniversalClipboardRelay.holdsOnlyStagedFiles([Self.staged, Self.original]))
        #expect(!UniversalClipboardRelay.holdsOnlyStagedFiles([]))
    }

    // MARK: - Reading a peer's bytes

    @Test("The file list is read under the key public.file-url crosses as")
    func readsTheMappedKey() {
        #expect(
            RepresentationKeyMap.canonical(forUTI: "public.file-url") == UniversalClipboardRelay.fileListKey)
    }

    @Test("A Mac's relay is recognised from its bytes, picture and all")
    func recognisesAMacRelay() {
        #expect(UniversalClipboardRelay.isRelay(Self.meta(), payloads: Self.stagedPayloads))
    }

    @Test("The original of a relayed copy is not a relay")
    func acceptsTheOriginal() {
        let payloads = [
            Self.fileList: Data(Self.original.absoluteString.utf8),
            Self.png: Data([0x89, 0x50, 0x4E, 0x47]),
        ]
        #expect(!UniversalClipboardRelay.isRelay(Self.meta(), payloads: payloads))
    }

    @Test("Bytes with no file list say nothing about relaying")
    func needsAFileList() {
        let picture = [Self.png: Data([0x89, 0x50, 0x4E, 0x47])]
        #expect(!UniversalClipboardRelay.isRelay(Self.meta(), payloads: picture))
        #expect(!UniversalClipboardRelay.isRelay(Self.meta(), payloads: [:]))
    }

    /// Rich text outranks a file URL at capture, so a relay carrying both is
    /// recorded as rich text and hashed by its text — the hash the original
    /// has too. Discarding it would tombstone the user's own copy everywhere.
    @Test("Only a file entry can be a relay: any other kind shares its hash with the original")
    func judgesOnlyFileEntries() {
        for kind in ["file", "folder", "imageFile"] {
            #expect(UniversalClipboardRelay.isRelay(Self.meta(kind: kind), payloads: Self.stagedPayloads))
        }
        for kind in ["text", "richText", "link", "image"] {
            #expect(!UniversalClipboardRelay.isRelay(Self.meta(kind: kind), payloads: Self.stagedPayloads))
        }
    }

    /// A fetch that runs out of budget can stop between two file lists. The
    /// one that did not arrive may name a file of the user's own, so a partial
    /// set of lists proves nothing.
    @Test("A relay is judged only once every file list the item declares has arrived")
    func needsEveryDeclaredFileList() {
        let linuxList = RepresentationKey(canonical: "text/uri-list", origin: "text/uri-list")
        let declared = [Self.fileList, linuxList].map { RepresentationDescriptor(key: $0, byteCount: 1) }
        let meta = Self.meta(representations: declared)
        let staged = Data(Self.staged.absoluteString.utf8)

        #expect(!UniversalClipboardRelay.isRelay(meta, payloads: [Self.fileList: staged]))
        #expect(UniversalClipboardRelay.isRelay(meta, payloads: [Self.fileList: staged, linuxList: staged]))
    }

    @Test("A uri-list with CRLF line ends, comments and a trailing NUL reads as its URLs")
    func readsAURIList() {
        let body = "# relayed\r\n\(Self.staged.absoluteString)\r\n\u{0}"
        let key = RepresentationKey(canonical: "text/uri-list", origin: "text/uri-list")
        #expect(UniversalClipboardRelay.fileURLs(in: Data(body.utf8)) == [Self.staged])
        #expect(UniversalClipboardRelay.isRelay(Self.meta(), payloads: [key: Data(body.utf8)]))
    }

    private static var stagedPayloads: [RepresentationKey: Data] {
        [
            fileList: Data(staged.absoluteString.utf8),
            png: Data([0x89, 0x50, 0x4E, 0x47]),
        ]
    }

    // MARK: - Discarding

    @Test("Discarding removes the row and tombstones it as this device, now")
    func discardsWithATombstone() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let meta = Self.meta(createdAt: now.addingTimeInterval(-2))
        let device = SyncFixtures.deviceB
        #expect(
            UniversalClipboardRelay.discarding(meta, by: device, at: now) == [
                .deleteLocally(contentHash: meta.contentHash),
                .recordTombstone(Tombstone(contentHash: meta.contentHash, deletedAt: now, deviceID: device)),
            ]
        )
    }

    /// A sender whose clock runs ahead stamps the relay after this device's
    /// "now". A tombstone older than the item loses to it in the merge, so it
    /// has to be stamped with the item's own time instead.
    @Test("The tombstone is never older than the relay it removes")
    func outlivesAFastSender() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let meta = Self.meta(createdAt: now.addingTimeInterval(5))
        let actions = UniversalClipboardRelay.discarding(meta, by: SyncFixtures.deviceB, at: now)
        let expected = Tombstone(
            contentHash: meta.contentHash,
            deletedAt: meta.createdAt,
            deviceID: SyncFixtures.deviceB
        )
        #expect(actions.last == .recordTombstone(expected))
    }

    static func meta(
        kind: String = "imageFile",
        createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        representations: [RepresentationDescriptor] = []
    ) -> SyncClipMeta {
        SyncClipMeta(
            contentHash: String(repeating: "c", count: 64),
            kind: kind,
            preview: "CleanShot 2026-09-18 at 23.55.42@2x.png",
            createdAt: createdAt,
            isPinned: LWWRegister(value: false, timestamp: createdAt, deviceID: SyncFixtures.deviceA),
            originDeviceID: SyncFixtures.deviceA,
            representations: representations
        )
    }
}

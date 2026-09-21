import Foundation
import SkrepkaCore
import SkrepkaIPC
import SkrepkaSync
import Testing

@testable import SkrepkaDaemon

/// The picker members act on the same stored rows the existing `History` member
/// lists, so these tests keep the selector and ordering boundary local.
@Suite("Daemon history members")
struct DaemonHistoryTests {
    private static func daemon() throws -> Daemon {
        var options = DaemonOptions()
        options.syncEnabled = false
        options.dataDirectory = FileManager.default.temporaryDirectory
            .appending(path: "skrepka-history-\(UUID().uuidString)", directoryHint: .isDirectory)
        return try Daemon(options: options, environment: [:])
    }

    private static func item(
        _ text: String,
        kind: ClipKind = .text,
        pinned: Bool = false,
        concealed: Bool = false,
        imageSize: ClipItem.ImageSize? = nil,
        representations: [String: Data]? = nil,
        createdAt: Date
    ) -> ClipItem {
        ClipItem(
            kind: kind,
            text: text,
            payload: ClipPayload(
                representations: representations ?? ["public.utf8-plain-text": Data(text.utf8)]),
            createdAt: createdAt,
            isPinned: pinned,
            isConcealed: concealed,
            imageSize: imageSize
        )
    }

    private static func record(_ item: ClipItem, in daemon: Daemon) async {
        _ = await daemon.historyStore.capture(item)
    }

    @Test("search keeps Matcher ranking, limits clips, and reports every match")
    func searchUsesMatcherOrderAndTotal() async throws {
        let daemon = try Self.daemon()
        let base = Date()
        await Self.record(Self.item("the alphabet", createdAt: base), in: daemon)
        await Self.record(Self.item("alpine", createdAt: base.addingTimeInterval(1)), in: daemon)
        await Self.record(Self.item("unrelated", createdAt: base.addingTimeInterval(2)), in: daemon)

        let document = await daemon.searchDocument(query: "al", limit: 1)
        #expect(document.total == 2)
        #expect(document.clips.map(\.preview) == ["alpine"])
    }

    @Test("blank search is exactly history")
    func blankSearchUsesHistoryOrder() async throws {
        let daemon = try Self.daemon()
        let base = Date()
        await Self.record(Self.item("first", createdAt: base), in: daemon)
        await Self.record(
            Self.item("second", pinned: true, createdAt: base.addingTimeInterval(1)), in: daemon)

        let history = await daemon.historyDocument(limit: 0)
        #expect(await daemon.searchDocument(query: "  \n", limit: 0) == history)
    }

    @Test("pinning is idempotent and deleting records the requested row")
    func pinsAndDeletesResolvedEntries() async throws {
        let daemon = try Self.daemon()
        let item = Self.item("keep me", createdAt: Date())
        await Self.record(item, in: daemon)

        let first = await daemon.setPinned(ClipSelector("1"), pinned: true)
        let second = await daemon.setPinned(ClipSelector("1"), pinned: true)
        #expect(first.ok)
        #expect(second.ok)
        #expect((try await daemon.historyStore.listing()).first?.summary.isPinned == true)

        let deleted = await daemon.delete(ClipSelector("1"))
        #expect(deleted.ok)
        #expect(try await daemon.historyStore.listing().isEmpty)
    }

    @Test("clear counts removed entries and optionally keeps pins")
    func clearRespectsPinnedEntries() async throws {
        let daemon = try Self.daemon()
        let base = Date()
        await Self.record(Self.item("pinned", pinned: true, createdAt: base), in: daemon)
        await Self.record(Self.item("ordinary", createdAt: base.addingTimeInterval(1)), in: daemon)

        let kept = await daemon.clear(keepingPinned: true)
        #expect(kept.detail == "cleared 1 entry")
        #expect(try await daemon.historyStore.listing().map(\.summary.text) == ["pinned"])

        let all = await daemon.clear(keepingPinned: false)
        #expect(all.detail == "cleared 1 entry")
        #expect(try await daemon.historyStore.listing().isEmpty)
    }

    @Test("plain copy exposes only the text target and refuses entries without one")
    func plainCopyTargets() {
        let text = Data("hello".utf8)
        let targets = Daemon.plainWritableTargets(
            from: ["public.utf8-plain-text": text, "public.html": Data("<b>hello</b>".utf8)])
        #expect(targets == ["text/plain;charset=utf-8": text])
        #expect(Daemon.plainWritableTargets(from: ["public.png": Data([1])]).isEmpty)
    }

    @Test("preview refuses concealed and non-picture entries, and observes the byte limit")
    func previewUnavailableCases() async throws {
        let daemon = try Self.daemon()
        let base = Date()
        await Self.record(Self.item("text", createdAt: base), in: daemon)
        await Self.record(
            Self.item(
                "secret",
                kind: .image,
                concealed: true,
                representations: ["public.png": Data([1])],
                createdAt: base.addingTimeInterval(1)
            ),
            in: daemon
        )
        await Self.record(
            Self.item(
                "picture",
                kind: .image,
                representations: ["public.png": Data([1, 2, 3])],
                createdAt: base.addingTimeInterval(2)
            ),
            in: daemon
        )

        let noPicture = await daemon.preview(ClipSelector("3"), maxBytes: 0)
        #expect(noPicture.data == nil)
        #expect(noPicture.detail == "that entry has no picture to preview")

        let concealed = await daemon.preview(ClipSelector("2"), maxBytes: 0)
        #expect(concealed.data == nil)
        #expect(concealed.detail == "that entry is concealed")

        let limited = await daemon.preview(ClipSelector("1"), maxBytes: 2)
        #expect(limited.data == nil)
        #expect(limited.byteCount == 3)
        #expect(limited.detail == "too large to preview")
    }

    @Test("preview clamps a request above its absolute byte cap")
    func previewClampsAnOversizedRequest() async throws {
        let daemon = try Self.daemon()
        let bytes = Data(repeating: 0, count: PreviewDocument.defaultByteLimit + 1)
        await Self.record(
            Self.item(
                "large picture",
                kind: .image,
                representations: ["public.png": bytes],
                createdAt: Date()
            ),
            in: daemon
        )

        let document = await daemon.preview(ClipSelector("1"), maxBytes: .max)
        #expect(document.data == nil)
        #expect(document.byteCount == bytes.count)
        #expect(document.detail == "too large to preview")
    }

    @Test("clip documents include row details and only advertise local pictures")
    func clipDocumentIncludesPickerFields() async throws {
        let daemon = try Self.daemon()
        let image = Self.item(
            "",
            kind: .image,
            imageSize: ClipItem.ImageSize(width: 20, height: 10),
            representations: ["public.png": Data([1])],
            createdAt: Date()
        )
        await Self.record(image, in: daemon)

        let listing = try #require(try await daemon.historyStore.listing().first)
        let document = Daemon.clipDocument(listing)
        #expect(document.lineCount == nil)
        #expect(document.imageWidth == 20)
        #expect(document.imageHeight == 10)
        #expect(document.fileCount == nil)
        #expect(document.isConcealed == false)
        #expect(document.hasPreview)
    }

    @Test("a peer-only picture is not advertised as previewable")
    func peerPictureWithoutBytesHasNoPreview() async throws {
        let daemon = try Self.daemon()
        let device = try #require(SyncDeviceID(hex: String(repeating: "a", count: SyncDeviceID.hexLength)))
        let stamp = Date()
        let key = RepresentationKey(canonical: "image/png", origin: "public.png")
        let meta = SyncClipMeta(
            contentHash: String(repeating: "b", count: 64),
            kind: ClipKind.image.rawValue,
            preview: "picture",
            createdAt: stamp,
            isPinned: LWWRegister(value: false, timestamp: stamp, deviceID: device),
            originDeviceID: device,
            representations: [RepresentationDescriptor(key: key, byteCount: 1)]
        )
        try await daemon.historyStore.capture(meta, payloads: [:])

        let listing = try #require(try await daemon.historyStore.listing().first)
        #expect(listing.representationTypes == ["public.png"])
        #expect(listing.localRepresentationTypes.isEmpty)
        #expect(Daemon.clipDocument(listing).hasPreview == false)
    }
}

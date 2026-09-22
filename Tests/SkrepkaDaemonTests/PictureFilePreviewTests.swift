import Foundation
import SkrepkaCore
import SkrepkaIPC
import SkrepkaSync
import Testing

@testable import SkrepkaDaemon

/// A picture copied in a file manager, as the picker sees it: an Image row with
/// a preview, drawn from the copy's bundle, or from the file itself when there
/// is no bundle — and never from a path another device named.
@Suite("Previews of copied picture files")
struct PictureFilePreviewTests {
    /// A 3 × 2 PNG written by ImageMagick; `SkrepkaCoreTests` has the rest of
    /// the formats.
    static let png =
        Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAEElEQVQI12P8zwAFTDAGAwATKQEDO7FpHgAAAABJRU5ErkJggg=="
        )
        ?? Data()

    /// A 3 × 2 GIF, from the same encoder.
    static let gif =
        Data(base64Encoded: "R0lGODlhAwACAPAAAP8AAAAAACH5BAAAAAAALAAAAAADAAIAAAIChF8AOw==") ?? Data()

    static func submitCopy(of file: URL, to daemon: Daemon) async -> Bool {
        await daemon.submit(
            SubmitRequest(representations: [
                "text/uri-list": Data(file.absoluteString.utf8).base64EncodedString()
            ])
        ).ok
    }

    @Test("a picture file copied here is an Image with its size, previewed from the copy's bundle")
    func previewedFromBundle() async throws {
        let (daemon, directory) = try ForeignFileWriteTests.daemon()
        let file = directory.appending(path: "shot.png")
        try Self.png.write(to: file)
        #expect(await Self.submitCopy(of: file, to: daemon))

        let clip = try #require(await daemon.historyDocument(limit: 0).clips.first)
        #expect(clip.kind == ClipKind.imageFile.rawValue)
        #expect(clip.imageWidth == 3)
        #expect(clip.imageHeight == 2)
        #expect(clip.hasPreview)

        // Deleted after the copy: the bundle is the picture as it was copied.
        try FileManager.default.removeItem(at: file)
        let preview = await daemon.preview(.hash(clip.contentHash), maxBytes: 0)
        #expect(preview.mediaType == "image/png")
        #expect(preview.bytes == Self.png)
    }

    @Test("with file sync off, the picture is read off disk when the row is drawn")
    func previewedFromDisk() async throws {
        let (daemon, directory) = try ForeignFileWriteTests.daemon()
        #expect(await daemon.applySettings(SettingsPatch(maximumFileSyncBytes: 0)).ok)
        let file = directory.appending(path: "loop.gif")
        try Self.gif.write(to: file)
        #expect(await Self.submitCopy(of: file, to: daemon))

        let entry = try #require(try await daemon.historyStore.listing().first)
        #expect(!entry.localRepresentationTypes.contains(FileBundle.storageType))
        let clip = try #require(await daemon.historyDocument(limit: 0).clips.first)
        #expect(clip.kind == ClipKind.imageFile.rawValue)
        #expect(clip.hasPreview)

        let preview = await daemon.preview(.hash(clip.contentHash), maxBytes: 0)
        #expect(preview.mediaType == "image/gif")
        #expect(preview.bytes == Self.gif)

        #expect(await daemon.preview(.hash(clip.contentHash), maxBytes: 8).detail == "too large to preview")

        try FileManager.default.removeItem(at: file)
        let gone = await daemon.preview(.hash(clip.contentHash), maxBytes: 0)
        #expect(gone.bytes == nil)
        #expect(gone.detail == "the copied picture is gone or can no longer be read")
    }

    @Test("a copied document is still a file, with no preview")
    func documentIsNotAPicture() async throws {
        let (daemon, directory) = try ForeignFileWriteTests.daemon()
        let file = directory.appending(path: "notes.png")
        try Data("a text file wearing a picture's name".utf8).write(to: file)
        #expect(await Self.submitCopy(of: file, to: daemon))

        let clip = try #require(await daemon.historyDocument(limit: 0).clips.first)
        #expect(clip.kind == ClipKind.file.rawValue)
        #expect(!clip.hasPreview)
    }

    @Test("a peer's picture file without its bundle is never read from this machine's disk")
    func foreignPathIsNeverRead() async throws {
        let (daemon, directory) = try ForeignFileWriteTests.daemon()
        // A picture really is at the path the peer names — which is exactly
        // the file this must not draw.
        let file = directory.appending(path: "shot.png")
        try Self.png.write(to: file)
        let device = try #require(SyncDeviceID(hex: FileSyncDocumentTests.peer))
        let stamp = Date()
        let hash = String(repeating: "6", count: 64)
        let key = RepresentationKey(canonical: "text/uri-list", origin: "public.file-url")
        let meta = SyncClipMeta(
            contentHash: hash,
            kind: ClipKind.imageFile.rawValue,
            preview: "shot.png",
            createdAt: stamp,
            isPinned: LWWRegister(value: false, timestamp: stamp, deviceID: device),
            originDeviceID: device,
            representations: [
                RepresentationDescriptor(key: key, byteCount: 64),
                RepresentationDescriptor(key: FileBundle.key, byteCount: 128),
            ]
        )
        try await daemon.historyStore.capture(meta, payloads: [key: Data(file.absoluteString.utf8)])

        let clip = try #require(await daemon.historyDocument(limit: 0).clips.first { $0.contentHash == hash })
        #expect(!clip.hasPreview)
        #expect(await daemon.preview(.hash(hash), maxBytes: 0).bytes == nil)
    }

    @Test("a peer's GIF file previews from its bundle")
    func syncedGIFPreviews() async throws {
        let (daemon, _) = try ForeignFileWriteTests.daemon()
        let hash = String(repeating: "7", count: 64)
        let bundle = FileBundle(files: [FileBundle.File(name: "loop.gif", bytes: Self.gif)])
        let encoded = try bundle.encoded()
        let payloads = FileSyncDocumentTests.uriPayload.merging([FileBundle.key: encoded]) { held, _ in held }
        try await daemon.historyStore.capture(
            try FileSyncDocumentTests.fileMeta(hash: hash, withBundle: true), payloads: payloads)

        let clip = try #require(await daemon.historyDocument(limit: 0).clips.first)
        #expect(clip.kind == ClipKind.imageFile.rawValue)
        #expect(clip.hasPreview)
        let preview = await daemon.preview(.hash(hash), maxBytes: 0)
        #expect(preview.mediaType == "image/gif")
        #expect(preview.bytes == Self.gif)
    }
}

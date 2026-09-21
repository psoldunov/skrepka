import Foundation
import Testing

@testable import SkrepkaSync

@Suite("File bundles on the wire")
struct FileBundleTests {
    static let pngHeader = Data(
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]
            + Array("IHDR".utf8) + [0, 0, 0x05, 0x12, 0, 0, 0x02, 0x86, 8, 6, 0, 0, 0]
    )

    @Test("A bundle round-trips through its encoding, names and bytes intact")
    func roundTrip() throws {
        let bundle = FileBundle(files: [
            FileBundle.File(name: "Screenshot 2026-09-21.png", bytes: Self.pngHeader),
            FileBundle.File(name: "notes ✏️.txt", bytes: Data("hello".utf8)),
            FileBundle.File(name: "empty", bytes: Data()),
        ])
        #expect(try FileBundle(encoded: bundle.encoded()) == bundle)
    }

    /// A later build may describe a file with more than these three fields,
    /// and this one must still read the three it knows — the rule every other
    /// message in the protocol follows.
    @Test("A key this build does not know is ignored")
    func unknownKeysAreTolerated() throws {
        let encoded = try CBOREncoder.encode(
            .array([
                .map(fields: [
                    "name": .text("a.txt"),
                    "size": .integer(2),
                    "bytes": .bytes(Data("hi".utf8)),
                    "modifiedAt": .integer(1_757_000_000_000),
                ])
            ])
        )
        let bundle = try FileBundle(encoded: encoded)
        #expect(bundle.files == [FileBundle.File(name: "a.txt", bytes: Data("hi".utf8))])
    }

    @Test("A size that disagrees with the bytes is refused")
    func mismatchedSizeIsRefused() throws {
        let encoded = try CBOREncoder.encode(
            .array([
                .map(fields: ["name": .text("a"), "size": .integer(3), "bytes": .bytes(Data("hi".utf8))])
            ])
        )
        #expect(throws: CBORError.self) { try FileBundle(encoded: encoded) }
    }

    @Test("Anything but an array is refused")
    func wrongShapeIsRefused() throws {
        let encoded = try CBOREncoder.encode(.map(fields: ["name": .text("a")]))
        #expect(throws: CBORError.self) { try FileBundle(encoded: encoded) }
    }

    @Test("A bundle past the payload ceiling is refused before it is decoded")
    func oversizedIsRefused() {
        let tooLarge = Data(count: SyncLimits.maximumPayloadBytes + 1)
        #expect(throws: CBORError.self) { try FileBundle(encoded: tooLarge) }
    }

    @Test("The bundle has a row in the map, and no clipboard target")
    func mapHasABundleRow() {
        #expect(RepresentationKeyMap.uti(forCanonical: FileBundle.canonicalKey) == FileBundle.storageType)
        #expect(RepresentationKeyMap.key(forUTI: FileBundle.storageType) == FileBundle.key)
        #expect(RepresentationKeyMap.linuxTarget(forCanonical: FileBundle.canonicalKey) == nil)
        let stored = RepresentationKeyMap.utiKeyed([FileBundle.key: Data([1])])
        #expect(stored[FileBundle.storageType] == Data([1]))
    }

    // MARK: - Pictures

    @Test("A single picture is recognised by its bytes, with its size")
    func singlePictureIsRecognised() throws {
        let bundle = FileBundle(files: [FileBundle.File(name: "shot.dat", bytes: Self.pngHeader)])
        let picture = try #require(bundle.singleImage)
        #expect(picture.type == .png)
        #expect(picture.type.storageType == "public.png")
        let size = try #require(picture.type.pixelSize(of: picture.bytes))
        #expect(size.width == 0x512 && size.height == 0x286)
    }

    @Test("Two files, or a file that is not a picture, are no picture")
    func notASinglePicture() {
        let two = FileBundle(files: [
            FileBundle.File(name: "a.png", bytes: Self.pngHeader),
            FileBundle.File(name: "b.png", bytes: Self.pngHeader),
        ])
        #expect(two.singleImage == nil)
        let text = FileBundle(files: [FileBundle.File(name: "a.png", bytes: Data("not a png".utf8))])
        #expect(text.singleImage == nil)
    }

    @Test("A JPEG states its size in its first start-of-frame")
    func jpegSize() throws {
        // SOI, an APP0 segment of length 4, then SOF0: length, precision,
        // height 0x01E0, width 0x0280.
        let jpeg = Data([
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00,
            0xFF, 0xC0, 0x00, 0x11, 0x08, 0x01, 0xE0, 0x02, 0x80, 0x03,
        ])
        #expect(ImageSignature(sniffing: jpeg) == .jpeg)
        let size = try #require(ImageSignature.jpeg.pixelSize(of: jpeg))
        #expect(size.width == 640 && size.height == 480)
    }

    @Test("A truncated header answers no size rather than trapping")
    func truncatedHeaders() {
        #expect(ImageSignature.png.pixelSize(of: Self.pngHeader.prefix(10)) == nil)
        #expect(ImageSignature.jpeg.pixelSize(of: Data([0xFF, 0xD8, 0xFF, 0xC0, 0x00])) == nil)
    }

    @Test("More files than the ceiling is refused both ways")
    func fileCountCeiling() throws {
        let file = FileBundle.File(name: "", bytes: Data())
        let tooMany = FileBundle(files: Array(repeating: file, count: FileBundle.maximumFileCount + 1))
        #expect(throws: CBORError.self) { try tooMany.encoded() }

        let empty = CBORValue.map(fields: ["name": .text(""), "size": .integer(0), "bytes": .bytes(Data())])
        let crafted = try CBOREncoder.encode(
            .array(Array(repeating: empty, count: FileBundle.maximumFileCount + 1))
        )
        #expect(throws: CBORError.self) { try FileBundle(encoded: crafted) }

        let atCeiling = FileBundle(files: Array(repeating: file, count: FileBundle.maximumFileCount))
        #expect(try FileBundle(encoded: atCeiling.encoded()) == atCeiling)
    }

    @Test("A frame naming anything but a content hash is refused")
    func malformedHashesAreRefused() throws {
        for hash in ["../../x", "aa", String(repeating: "A", count: 64)] {
            let item = try FrameCodec.encode(.itemMeta(SyncFixtures.meta(hash)))
            var buffer = item
            #expect(throws: (any Error).self) { try FrameCodec.decodeMessage(from: &buffer) }

            let deletion = try FrameCodec.encode(.tombstone([SyncFixtures.tombstone(hash)]))
            buffer = deletion
            #expect(throws: (any Error).self) { try FrameCodec.decodeMessage(from: &buffer) }
        }
        var valid = try FrameCodec.encode(.itemMeta(SyncFixtures.meta(SyncFixtures.wireHash("ab"))))
        #expect(try FrameCodec.decodeMessage(from: &valid) != nil)
    }
}

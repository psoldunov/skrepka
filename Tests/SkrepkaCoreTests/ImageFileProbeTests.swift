import Foundation
import SkrepkaSync
import Testing

@testable import SkrepkaCore

@Suite("Telling a copied picture file from any other file, without decoding it")
struct ImageFileProbeTests {
    typealias Pictures = Fixtures.Pictures

    static func copy(of urls: [URL], bundle: FileBundle? = nil) throws -> ClipItem {
        var representations = Fixtures.fileURLPayload(try #require(urls.first)).representations
        if let bundle { representations[FileBundle.storageType] = try bundle.encoded() }
        return ClipItem(
            kind: .file,
            text: urls.map(\.lastPathComponent).joined(separator: "\n"),
            payload: ClipPayload(representations: representations),
            fileURLs: urls
        )
    }

    @Test("a copied picture file becomes an image file, sized from its header, under the same hash")
    func pictureOnDisk() async throws {
        let url = try Pictures.write(Pictures.webPLossless, named: "sticker.webp")
        let copy = try Self.copy(of: [url])

        let refined = await ImageFileProbe.refining(copy)
        #expect(refined.kind == .imageFile)
        #expect(refined.imageSize == ClipItem.ImageSize(width: 3, height: 2))
        #expect(refined.contentHash == copy.contentHash)
        #expect(refined.id == copy.id)
        #expect(refined.fileURLs == copy.fileURLs)
    }

    @Test("a portrait photo is sized the way it is shown")
    func rotatedPhoto() async throws {
        let url = try Pictures.write(Pictures.jpegRotatedRight, named: "IMG_0001.jpg")
        let refined = await ImageFileProbe.refining(try Self.copy(of: [url]))
        #expect(refined.imageSize == ClipItem.ImageSize(width: 2, height: 3))
    }

    @Test("the bundle read at the copy is the evidence, not the file as it is now")
    func bundleWins() async throws {
        let url = try Pictures.write(Pictures.gif, named: "loop.gif")
        let copy = try Self.copy(
            of: [url], bundle: FileBundle(files: [FileBundle.File(name: "loop.gif", bytes: Pictures.gif)]))
        // Overwritten after the copy: the bundle still holds the picture.
        try Data("no longer a picture".utf8).write(to: url)

        #expect(await ImageFileProbe.refining(copy).kind == .imageFile)

        // And the other way round: a bundle that is not a picture settles it,
        // whatever the path holds now.
        let text = try Self.copy(
            of: [url],
            bundle: FileBundle(files: [FileBundle.File(name: "loop.gif", bytes: Data("text".utf8))]))
        try Pictures.gif.write(to: url)
        #expect(await ImageFileProbe.refining(text).kind == .file)
    }

    @Test("a document, a folder, a missing file and several pictures stay files")
    func notOnePicture() async throws {
        let document = try Self.copy(of: [try Fixtures.writeTextFile(named: "notes.txt")])
        #expect(await ImageFileProbe.refining(document) == document)

        let folder = try Fixtures.makeDirectory()
        #expect(await ImageFileProbe.refining(try Self.copy(of: [folder])).kind == .file)

        let missing = folder.appending(path: "gone.png")
        #expect(await ImageFileProbe.refining(try Self.copy(of: [missing])).kind == .file)

        let first = try Pictures.write(Pictures.png, named: "one.png")
        let second = try Pictures.write(Pictures.png, named: "two.png")
        #expect(await ImageFileProbe.refining(try Self.copy(of: [first, second])).kind == .file)
    }

    @Test("only a copy the capture rules called a file is looked at")
    func otherKindsUntouched() async throws {
        let url = try Pictures.write(Pictures.png, named: "shot.png")
        let concealed = ClipItem(
            kind: .file, text: "shot.png", payload: Fixtures.fileURLPayload(url), isConcealed: true)
        #expect(await ImageFileProbe.refining(concealed).kind == .file)

        let text = ClipItem(kind: .text, text: url.path, payload: ClipPayload(representations: [:]))
        #expect(await ImageFileProbe.refining(text) == text)
    }

    @Test("the picture a row names is read back whole, within the limit, and nothing else is")
    func pictureAtURL() async throws {
        let url = try Pictures.write(Pictures.bmp, named: "icon.bmp")
        #expect(
            await ImageFileProbe.picture(atFileURL: url, limit: 1024) == .picture(.bmp, Pictures.bmp))
        #expect(await ImageFileProbe.picture(atFileURL: url, limit: 16) == .tooLarge)

        let document = try Fixtures.writeTextFile(named: "notes.txt")
        #expect(await ImageFileProbe.picture(atFileURL: document, limit: 1024) == .unavailable)
        let missing = document.deletingLastPathComponent().appending(path: "gone.png")
        #expect(await ImageFileProbe.picture(atFileURL: missing, limit: 1024) == .unavailable)
        let remote = try #require(URL(string: "https://example.com/shot.png"))
        #expect(await ImageFileProbe.picture(atFileURL: remote, limit: 1024) == .unavailable)
    }

    @Test("a bundle's one file is its picture in any format a row can show")
    func bundledPicture() throws {
        let gif = try FileBundle(files: [FileBundle.File(name: "loop.gif", bytes: Pictures.gif)]).encoded()
        let picture = try #require(ImageFileProbe.bundledPicture(in: [FileBundle.storageType: gif]))
        #expect(picture.header.format == .gif)
        #expect(picture.bytes == Pictures.gif)

        let two = try FileBundle(files: [
            FileBundle.File(name: "a.gif", bytes: Pictures.gif),
            FileBundle.File(name: "b.gif", bytes: Pictures.gif),
        ]).encoded()
        #expect(ImageFileProbe.bundledPicture(in: [FileBundle.storageType: two]) == nil)
        #expect(ImageFileProbe.bundledPicture(in: [FileBundle.storageType: Data("junk".utf8)]) == nil)
        #expect(ImageFileProbe.bundledPicture(in: [:]) == nil)
    }
}

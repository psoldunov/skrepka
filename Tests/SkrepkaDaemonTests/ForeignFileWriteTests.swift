import Foundation
import SkrepkaCore
import SkrepkaSync
import Testing

@testable import SkrepkaDaemon

/// What a file row puts on this machine's clipboard — above all, that a row
/// another device recorded never hands the clipboard that device's path.
///
/// The field report this pins: a Mac file copy reached Dolphin as
/// `/Users/…/CleanShot … .png`, which does not exist on Linux.
@Suite("A file row from another device pastes as local files or as names")
struct ForeignFileWriteTests {
    static func daemon() throws -> (Daemon, URL) {
        var options = DaemonOptions()
        options.syncEnabled = false
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "skrepka-files-\(UUID().uuidString)", directoryHint: .isDirectory)
        options.dataDirectory = directory
        return (try Daemon(options: options, environment: [:]), directory)
    }

    /// Enough of a PNG for `ImageSignature` to recognise it.
    static let png = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
    ])

    static let hash = String(repeating: "a", count: 64)
    static let macPath = "file:///Users/philipp/Desktop/CleanShot%202026.png"

    static func source(
        bundle: FileBundle?,
        kind: ClipKind = .file,
        isForeign: Bool = true
    ) throws -> WritableRow {
        var representations = [PasteboardType.fileURL: Data(macPath.utf8)]
        if let bundle { representations[FileBundle.storageType] = try bundle.encoded() }
        return WritableRow(
            kind: kind,
            representations: representations,
            fileURLs: [],
            preview: "CleanShot 2026.png",
            contentHash: hash,
            isForeign: isForeign
        )
    }

    static func text(_ data: Data?) -> String {
        data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    @Test("a picture file with its bundle pastes as a local file, in both list formats, and as the picture")
    func bundledPictureIsMaterialised() async throws {
        let (daemon, directory) = try Self.daemon()
        let bundle = FileBundle(files: [FileBundle.File(name: "CleanShot 2026.png", bytes: Self.png)])

        let write = await daemon.clipboardWrite(for: try Self.source(bundle: bundle))
        let targets = write.targets

        let cacheRoot = directory.appending(path: "cache/files/\(Self.hash)").path
        let uriList = Self.text(targets["text/uri-list"])
        let gnome = Self.text(targets["x-special/gnome-copied-files"])
        #expect(uriList.hasPrefix("file://"))
        #expect(URL(string: uriList)?.path.hasPrefix(cacheRoot) == true)
        #expect(gnome.hasPrefix("copy\nfile://"))
        #expect(gnome.dropFirst("copy\n".count) == Substring(uriList))
        #expect(targets["image/png"] == Self.png)
        #expect(targets.values.allSatisfy { !Self.text($0).contains("/Users/") })
        let written = try #require(write.fileURLs.first)
        #expect(try Data(contentsOf: written) == Self.png)
        #expect(write.replacesRow)
    }

    @Test("every file of a multi-file bundle is offered")
    func everyFileIsOffered() async throws {
        let (daemon, _) = try Self.daemon()
        let bundle = FileBundle(files: [
            FileBundle.File(name: "a.txt", bytes: Data("a".utf8)),
            FileBundle.File(name: "b.txt", bytes: Data("b".utf8)),
        ])

        let targets = await daemon.clipboardWrite(for: try Self.source(bundle: bundle)).targets

        let lines = Self.text(targets["x-special/gnome-copied-files"]).split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines.last?.hasSuffix("/b.txt") == true)
        #expect(Self.text(targets["text/uri-list"]).components(separatedBy: "\r\n").count == 2)
        #expect(targets["image/png"] == nil)
    }

    @Test("a foreign file row with no bundle pastes as its names, never as the sender's path")
    func unbundledRowPastesNames() async throws {
        let (daemon, _) = try Self.daemon()

        let write = await daemon.clipboardWrite(for: try Self.source(bundle: nil))

        #expect(Array(write.targets.keys) == ["text/plain;charset=utf-8"])
        #expect(Self.text(write.targets["text/plain;charset=utf-8"]) == "CleanShot 2026.png")
        #expect(write.targets.values.allSatisfy { !Self.text($0).contains("file://") })
        #expect(write.plainTargets == write.targets)
    }

    @Test("a local multi-file row offers every file it names in both formats")
    func localRowOffersEveryFile() async throws {
        let (daemon, _) = try Self.daemon()
        let files = [URL(filePath: "/home/deck/a.txt"), URL(filePath: "/home/deck/b.txt")]
        let source = WritableRow(
            kind: .file,
            representations: [PasteboardType.fileURL: Data(files[0].absoluteString.utf8)],
            fileURLs: files,
            preview: "a.txt\nb.txt",
            contentHash: Self.hash,
            isForeign: false
        )

        let write = await daemon.clipboardWrite(for: source)

        let gnome = Self.text(write.targets["x-special/gnome-copied-files"])
        #expect(gnome == "copy\nfile:///home/deck/a.txt\nfile:///home/deck/b.txt")
        let uriList = Self.text(write.targets["text/uri-list"])
        #expect(uriList == "file:///home/deck/a.txt\r\nfile:///home/deck/b.txt")
        #expect(write.replacesRow == false)
    }

    @Test("a row with no origin is local; an origin other than this device's is foreign")
    func foreignness() {
        #expect(Daemon.isForeign(origin: nil, local: "aa") == false)
        #expect(Daemon.isForeign(origin: "aa", local: "aa") == false)
        #expect(Daemon.isForeign(origin: "bb", local: "aa"))
        #expect(Daemon.isForeign(origin: "bb", local: nil))
    }
}

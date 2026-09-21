import Foundation
import SkrepkaSync
import Testing

@testable import SkrepkaCore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

@Suite("Reading copied files into a bundle")
struct FileBundleReaderTests {
    @Test("Every regular file is read, in copy order, and folders are skipped")
    func readsFilesSkipsFolders() throws {
        let first = try Fixtures.writeTextFile("one", named: "b.txt")
        let second = try Fixtures.writeTextFile("two", named: "a.txt")
        let folder = try Fixtures.makeDirectory()

        let outcome = FileBundleReader.read([first, folder, second])
        guard case .bundle(let bundle) = outcome else {
            Issue.record("expected a bundle, got \(outcome)")
            return
        }
        #expect(bundle.files.map(\.name) == ["b.txt", "a.txt"])
        #expect(bundle.files.map(\.bytes) == [Data("one".utf8), Data("two".utf8)])
    }

    @Test("A copy of folders alone, or of files since deleted, bundles nothing")
    func nothingToBundle() throws {
        let gone = try Fixtures.makeDirectory().appending(path: "gone.txt", directoryHint: .notDirectory)
        #expect(FileBundleReader.read([try Fixtures.makeDirectory()]) == .nothingToBundle)
        #expect(FileBundleReader.read([gone]) == .nothingToBundle)
        #expect(FileBundleReader.read([]) == .nothingToBundle)
    }

    @Test("Files over the limit together bundle nothing at all")
    func overTheLimit() throws {
        let first = try Fixtures.writeTextFile("123456", named: "a.bin")
        let second = try Fixtures.writeTextFile("123456", named: "b.bin")
        #expect(FileBundleReader.read([first, second], limit: 11) == .tooLarge)
        guard case .bundle = FileBundleReader.read([first, second], limit: 12) else {
            Issue.record("twelve bytes fit a twelve-byte limit")
            return
        }
    }

    @Test("A symlink is read through, under the name the user copied")
    func symlinkKeepsItsName() throws {
        let target = try Fixtures.writeTextFile("target", named: "real.txt")
        let link = try Fixtures.makeDirectory().appending(path: "alias.txt", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        guard case .bundle(let bundle) = FileBundleReader.read([link]) else {
            Issue.record("a symlink to a file is a file")
            return
        }
        #expect(bundle.files == [FileBundle.File(name: "alias.txt", bytes: Data("target".utf8))])
    }

    @Test("Attaching adds the bundle as a representation and folds it into the hash")
    func attachingKeepsIdentity() async throws {
        let url = try Fixtures.writeTextFile("contents", named: "note.txt")
        let item = ClipItem(kind: .file, text: "note.txt", payload: Fixtures.fileURLPayload(url))

        let attached = await FileBundleReader.attachingBundle(to: item)
        #expect(attached.contentHash != item.contentHash)
        #expect(ContentHash.isValid(attached.contentHash))
        #expect(attached.id == item.id)
        #expect(attached.fileURLs == item.fileURLs)
        let encoded = try #require(attached.payload.data(forType: FileBundle.storageType))
        #expect(try FileBundle(encoded: encoded).files.map(\.name) == ["note.txt"])
        #expect(
            attached.payload.data(forType: PasteboardType.fileURL)
                == item.payload.data(forType: PasteboardType.fileURL))

        // Once is enough: a second pass reads nothing and changes nothing.
        #expect(await FileBundleReader.attachingBundle(to: attached) == attached)
    }

    @Test("A limit of zero reads nothing at all, and a limit under the files bundles nothing")
    func limitIsHonoured() async throws {
        let url = try Fixtures.writeTextFile("twelve bytes", named: "note.txt")
        let item = ClipItem(kind: .file, text: "note.txt", payload: Fixtures.fileURLPayload(url))
        #expect(await FileBundleReader.attachingBundle(to: item, limit: 0) == item)
        #expect(await FileBundleReader.attachingBundle(to: item, limit: 5) == item)
        let bundled = await FileBundleReader.attachingBundle(to: item, limit: 1_024)
        #expect(bundled.payload.data(forType: FileBundle.storageType) != nil)
    }

    @Test("Text, concealed copies and folders are left as they are")
    func nothingToAttach() async throws {
        let text = ClipItem(kind: .text, text: "hi", payload: ClipPayload(representations: [:]))
        #expect(await FileBundleReader.attachingBundle(to: text) == text)

        let url = try Fixtures.writeTextFile("secret", named: "secret.txt")
        let concealed = ClipItem(
            kind: .file, text: "secret.txt", payload: Fixtures.fileURLPayload(url), isConcealed: true)
        #expect(await FileBundleReader.attachingBundle(to: concealed) == concealed)

        let folder = try Fixtures.makeDirectory()
        let folderCopy = ClipItem(kind: .folder, text: "folder", payload: Fixtures.fileURLPayload(folder))
        #expect(await FileBundleReader.attachingBundle(to: folderCopy) == folderCopy)
    }

    @Test("A file edited in place and copied again is a new item; an identical re-copy is not")
    func contentsAreIdentity() async throws {
        let url = try Fixtures.writeTextFile("first shot", named: "shot.png")
        let copy = { ClipItem(kind: .file, text: "shot.png", payload: Fixtures.fileURLPayload(url)) }

        let first = await FileBundleReader.attachingBundle(to: copy())
        let again = await FileBundleReader.attachingBundle(to: copy())
        #expect(again.contentHash == first.contentHash)

        try Data("second shot".utf8).write(to: url)
        let edited = await FileBundleReader.attachingBundle(to: copy())
        #expect(edited.contentHash != first.contentHash)
        // Without a bundle the hash is the path's, as it always was.
        #expect(
            copy().contentHash
                == ClipItem(kind: .file, text: "x", payload: Fixtures.fileURLPayload(url)).contentHash)
    }

    @Test("A FIFO swapped in for a file is skipped, not waited on")
    func fifoIsSkipped() throws {
        let fifo = try Fixtures.makeDirectory().appending(path: "pipe", directoryHint: .notDirectory)
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let file = try Fixtures.writeTextFile("real", named: "real.txt")

        guard case .bundle(let bundle) = FileBundleReader.read([fifo, file]) else {
            Issue.record("the regular file still travels")
            return
        }
        #expect(bundle.files.map(\.name) == ["real.txt"])
    }

    @Test("A device reads as no file at all, however much it would yield")
    func deviceIsSkipped() {
        #expect(FileBundleReader.read([URL(fileURLWithPath: "/dev/zero")]) == .nothingToBundle)
    }

    @Test("More files than a bundle may carry cross as names")
    func tooManyFiles() throws {
        let directory = try Fixtures.makeDirectory()
        let urls = try (0...FileBundle.maximumFileCount).map { index in
            let url = directory.appending(path: "\(index)", directoryHint: .notDirectory)
            try Data().write(to: url)
            return url
        }
        #expect(FileBundleReader.read(urls) == .tooLarge)
        guard case .bundle = FileBundleReader.read(Array(urls.dropLast())) else {
            Issue.record("exactly the maximum fits")
            return
        }
    }
}

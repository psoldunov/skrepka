import Foundation
import Testing

@testable import SkrepkaCore

@Suite("Content size")
struct ContentSizeTests {
    private func item(kind: ClipKind, payload: ClipPayload) -> ClipItem {
        ClipItem(kind: kind, text: "entry", payload: payload)
    }

    private func write(_ byteCount: Int, to url: URL) throws {
        try Data(repeating: 0x41, count: byteCount).write(to: url)
    }

    // MARK: - Files

    @Test("A copied file reports its own size")
    func measuresFile() throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "notes.txt", directoryHint: .notDirectory)
        try write(5000, to: file)

        let measured = ContentSize.byteCount(of: item(kind: .file, payload: Fixtures.fileURLPayload(file)))
        // The logical size, not the size on disk: a 5,000-byte file occupies
        // two 4 KB blocks, and Finder's Get Info leads with 5,000 too.
        #expect(measured == 5000)
    }

    @Test("A copy of several files reports what all of them weigh")
    func measuresWholeSelection() throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appending(path: "a.bin", directoryHint: .notDirectory)
        let second = directory.appending(path: "b.bin", directoryHint: .notDirectory)
        try write(1000, to: first)
        try write(500, to: second)

        let selection = ClipItem(
            kind: .file,
            text: "a.bin\nb.bin",
            payload: Fixtures.fileURLPayload(first),
            fileURLs: [first, second]
        )
        #expect(ContentSize.byteCount(of: selection) == 1500)
    }

    @Test("A selection with an unmeasurable file in it reports no size")
    func partialSelectionHasNoSize() throws {
        // The rule `DirectorySize` states, applied one level up: two files out
        // of three is a wrong number that looks like a right one.
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let present = directory.appending(path: "a.bin", directoryHint: .notDirectory)
        try write(1000, to: present)
        let missing = directory.appending(path: "gone.bin", directoryHint: .notDirectory)

        let selection = ClipItem(
            kind: .file,
            text: "a.bin\ngone.bin",
            payload: Fixtures.fileURLPayload(present),
            fileURLs: [present, missing]
        )
        #expect(ContentSize.byteCount(of: selection) == nil)
    }

    @Test("A copied folder reports the sum of everything under it")
    func measuresFolderRecursively() throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write(1000, to: directory.appending(path: "a.bin", directoryHint: .notDirectory))
        try write(234, to: nested.appending(path: "b.bin", directoryHint: .notDirectory))

        let measured = ContentSize.byteCount(
            of: item(kind: .folder, payload: Fixtures.fileURLPayload(directory))
        )
        #expect(measured == 1234)
    }

    @Test("A symlink is not counted as a second copy of its target")
    func ignoresSymlinks() throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "a.bin", directoryHint: .notDirectory)
        try write(1000, to: file)
        try FileManager.default.createSymbolicLink(
            at: directory.appending(path: "alias.bin", directoryHint: .notDirectory),
            withDestinationURL: file
        )

        let measured = ContentSize.byteCount(
            of: item(kind: .folder, payload: Fixtures.fileURLPayload(directory))
        )
        #expect(measured == 1000)
    }

    @Test("An application bundle is measured through, even though it is a file")
    func measuresPackageContents() throws {
        let bundle = try Fixtures.makePackage(named: "Probe.app")
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        try write(700, to: bundle.appending(path: "payload.bin", directoryHint: .notDirectory))

        // `.app` classifies as `.file` — see `FileURLKind` — but its size is
        // still everything inside it, which is what Finder reports too.
        let measured = ContentSize.byteCount(of: item(kind: .file, payload: Fixtures.fileURLPayload(bundle)))
        #expect(measured == 700)
    }

    @Test("A file the disk cannot answer for has no size")
    func missingFileHasNoSize() throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gone = directory.appending(path: "gone.bin", directoryHint: .notDirectory)

        #expect(ContentSize.byteCount(of: item(kind: .file, payload: Fixtures.fileURLPayload(gone))) == nil)
    }

    // MARK: - The deadline

    @Test("A folder too large to walk in time reports nothing, not a partial sum")
    func abandonsOversizedFolder() throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<8 {
            try write(1, to: directory.appending(path: "\(index).bin", directoryHint: .notDirectory))
        }

        // A partial total would read as a real measurement. Nothing is honest.
        #expect(DirectorySize.byteCount(ofDirectoryAt: directory, deadline: .zero) == nil)
        // The same folder measures fine when there is time for it.
        #expect(DirectorySize.byteCount(ofDirectoryAt: directory) == 8)
    }

    @Test("A folder of one file is checked against the deadline too")
    func checksDeadlineOnEveryEntry() throws {
        // The clock used to be read once per 512 entries, so a folder smaller
        // than that ran to completion however slow the volume under it. Small
        // is not the same as fast.
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(42, to: directory.appending(path: "a.bin", directoryHint: .notDirectory))

        #expect(DirectorySize.byteCount(ofDirectoryAt: directory, deadline: .zero) == nil)
        #expect(DirectorySize.byteCount(ofDirectoryAt: directory) == 42)
    }

    @Test("An empty folder measures zero rather than giving up")
    func emptyFolderIsZero() throws {
        // Nothing to walk means nothing to run out of time on, so even an
        // expired deadline yields an answer.
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(DirectorySize.byteCount(ofDirectoryAt: directory, deadline: .zero) == 0)
    }

    // MARK: - Pasteboard data

    @Test("An image copied as data reports the richest representation, not the sum")
    func measuresRichestImageRepresentation() {
        let payload = ClipPayload(representations: [
            PasteboardType.png: Data(repeating: 0, count: 300),
            PasteboardType.tiff: Data(repeating: 0, count: 900),
        ])
        // One picture, offered twice. Adding both would report a 300-byte
        // screenshot as 1.2 kB.
        #expect(ContentSize.byteCount(of: item(kind: .image, payload: payload)) == 300)
    }

    @Test("Text-shaped kinds have no size worth showing")
    func textHasNoSize() {
        let payload = ClipPayload(representations: [PasteboardType.string: Data("hello".utf8)])
        #expect(ContentSize.byteCount(of: item(kind: .text, payload: payload)) == nil)
        #expect(ContentSize.byteCount(of: item(kind: .richText, payload: payload)) == nil)
        #expect(ContentSize.byteCount(of: item(kind: .link, payload: payload)) == nil)
    }
}

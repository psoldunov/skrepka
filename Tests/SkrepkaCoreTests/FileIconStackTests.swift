import AppKit
import Foundation
import Testing

@testable import SkrepkaCore

/// The pictures a row holding several files stacks: one per file, the file's
/// own where it has one.
@Suite("File icon stack")
struct FileIconStackTests {
    /// Pixel dimensions of a PNG, so a test can tell "an icon came back" from
    /// "some bytes came back".
    private func size(of data: Data) throws -> (width: Int, height: Int) {
        let image = try #require(NSImage(data: data))
        let rep = try #require(image.representations.first)
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    @Test("One picture per file, in the order the entry lists them")
    func onePicturePerFile() throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let picture = directory.appending(path: "shot.png", directoryHint: .notDirectory)
        try Fixtures.png(width: 60, height: 40).write(to: picture)
        let document = directory.appending(path: "notes.txt", directoryHint: .notDirectory)
        try Data("hello".utf8).write(to: document)

        let icons = FileIconStack.icons(forFilesAt: [picture, document])
        #expect(icons.count == 2)
        // The picture is drawn from its own bytes, so it keeps its shape; the
        // document falls back to the square system icon.
        let front = try size(of: icons[0])
        #expect(front.width > front.height)
        let behind = try size(of: icons[1])
        #expect(behind.width == behind.height)
    }

    @Test("A file with no picture in it still gets its icon")
    func documentFallsBackToItsSystemIcon() throws {
        let document = try Fixtures.writeTextFile(named: "notes.txt")
        defer { try? FileManager.default.removeItem(at: document.deletingLastPathComponent()) }

        let icon = try #require(FileIconStack.icon(forFileAt: document))
        let drawn = try size(of: icon)
        #expect(drawn.width == FileIconStack.maximumEdge)
        #expect(drawn.height == FileIconStack.maximumEdge)
    }

    @Test("A folder and a document do not wear the same icon")
    func differentFilesLookDifferent() throws {
        // The whole point of drawing the files rather than a generic card: a
        // stack should say *which* files, so two kinds must not render alike.
        let folder = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appending(path: "notes.txt", directoryHint: .notDirectory)
        try Data("hello".utf8).write(to: document)

        let folderIcon = try #require(FileIconStack.icon(forFileAt: folder))
        let documentIcon = try #require(FileIconStack.icon(forFileAt: document))
        #expect(folderIcon != documentIcon)
    }

    @Test("A deleted file still draws, because the row is drawn after the copy")
    func missingFileStillDraws() throws {
        // `NSWorkspace` answers for a path that no longer exists — with the
        // generic document icon, which is the honest picture of a file we can
        // no longer look inside. A nil here would leave a gap in the stack.
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appending(path: "gone.txt", directoryHint: .notDirectory)

        #expect(FileIconStack.icon(forFileAt: missing) != nil)
    }

    @Test("A file missing from disk does not shorten the stack")
    func missingFileDoesNotShortenTheStack() throws {
        // The stack is every layer or none: depth carries meaning, so a stack
        // short one layer would promote the second file to the front and picture
        // it as the one the row leads with. A deleted file is the near miss —
        // it still draws, as its generic icon, so the depth is kept honestly
        // rather than by luck.
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let present = directory.appending(path: "a.txt", directoryHint: .notDirectory)
        try Data("hello".utf8).write(to: present)
        let missing = directory.appending(path: "gone.txt", directoryHint: .notDirectory)

        #expect(FileIconStack.icons(forFilesAt: [present, missing]).count == 2)
    }

    @Test("A copy of more files than the stack shows is cut to the stack")
    func stopsAtTheCeiling() throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try (0..<(FileSelection.maximumStackedIcons + 2)).map { index -> URL in
            let url = directory.appending(path: "file-\(index).txt", directoryHint: .notDirectory)
            try Data("x".utf8).write(to: url)
            return url
        }

        #expect(FileIconStack.icons(forFilesAt: files).count == FileSelection.maximumStackedIcons)
        #expect(FileIconStack.icons(forFilesAt: []).isEmpty)
    }
}

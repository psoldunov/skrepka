import Foundation
import Testing

@testable import SkrepkaCore

/// Telling a copied folder from a copied file, which only the file system can
/// do — and saying so when it will not.
@Suite("File URL kind")
struct FileURLKindTests {
    @Test("A plain directory is a folder")
    func directoryIsFolder() throws {
        // The bug: Finder writes one `public.file-url` whether the user copied
        // a document or a folder, so every row read "File" and wore a document
        // icon.
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(FileURLKind.kind(ofFileAt: directory) == .folder)
    }

    @Test("An application bundle is a file, not a folder")
    func packageIsFile() throws {
        // `.app` is a directory on disk, but Finder shows it as one item and so
        // do we — and a folder would lose its preview, since `.folder` is never
        // sent to the thumbnail maker.
        let bundle = try Fixtures.makePackage(named: "ChatGPT.app")
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

        #expect(FileURLKind.kind(ofFileAt: bundle) == .file)
    }

    @Test("A regular file is a file")
    func regularFileIsFile() throws {
        let url = try Fixtures.writeTextFile(named: "notes.txt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(FileURLKind.kind(ofFileAt: url) == .file)
    }

    @Test("A picture on disk is an image, not a file")
    func imageFileIsImage() throws {
        // The bug: a screenshot copied out of Finder arrives as a
        // `public.file-url`, so the row read "File" beside its own preview.
        let url = try Fixtures.writePNG(width: 2, height: 2, named: "shot.png")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(FileURLKind.kind(ofFileAt: url) == .imageFile)
    }

    @Test("A selection of pictures is images; a mixed one is files")
    func selectionTakesTheSharedKind() throws {
        let first = try Fixtures.writePNG(width: 2, height: 2, named: "one.png")
        let second = try Fixtures.writePNG(width: 3, height: 3, named: "two.png")
        let text = try Fixtures.writeTextFile(named: "notes.txt")
        defer {
            for url in [first, second, text] {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }

        #expect(FileURLKind.kind(ofFilesAt: [first, second]) == .imageFile)
        #expect(FileURLKind.kind(ofFilesAt: [first, text]) == .file)
        #expect(FileURLKind.kind(ofFilesAt: []) == nil)
    }

    @Test("A selection that runs out of budget answers nothing at all")
    func selectionOutOfBudgetIsNil() throws {
        // Not `.file`: nil is what "I could not look" has to mean, because
        // ``HistoryStore`` writes a refined kind onto an existing row only when
        // one came back. Answering `.file` here downgraded a row already reading
        // "300 Images" the first time that copy was made off a slow volume.
        let url = try Fixtures.writePNG(width: 2, height: 2, named: "shot.png")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(FileURLKind.kind(ofFilesAt: [url], deadline: .zero) == nil)
        #expect(FileURLKind.kind(ofFilesAt: [url]) == .imageFile)
    }

    @Test("A selection nothing in it can be described answers nothing at all")
    func unanswerableSelectionIsNil() throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appending(path: "gone", directoryHint: .notDirectory)

        #expect(FileURLKind.kind(ofFilesAt: [missing, missing]) == nil)
    }

    @Test("A path the disk will not describe answers nothing at all")
    func unanswerablePathIsNil() throws {
        // Deleted since the copy, or on a volume that is no longer mounted. Nil
        // rather than `.file`: a caller storing a fresh row falls back to
        // `.file` anyway, but a caller holding a row that already says Folder
        // needs to tell "it is a file" from "I could not look".
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appending(path: "gone", directoryHint: .notDirectory)

        #expect(FileURLKind.kind(ofFileAt: missing) == nil)
    }
}

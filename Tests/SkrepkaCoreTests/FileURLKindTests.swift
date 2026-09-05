// Fenced to Apple platforms, unlike the type it tests, which compiles anywhere.
// `.isPackageKey` is Finder's presentation model: swift-corelibs-foundation has
// no notion of a bundle, so asserting that `ChatGPT.app` is a file rather than a
// folder is an assertion about macOS. Phase 7 gives Linux its own answer.
#if canImport(AppKit)

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
            let url = try Fixtures.writePNG(width: 2, height: 2, named: "shot.png")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            #expect(FileURLKind.kind(ofFileAt: url) == .file)
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

#endif

// Fenced to Apple platforms, unlike the type it tests, which compiles anywhere.
// Not because `.isPackageKey` is unavailable off Darwin — swift-corelibs-
// foundation answers it, and answers `true` for a bare `ChatGPT.app` directory,
// verified by probing Swift 6.3 on `aarch64-unknown-linux-gnu`. The fence is
// here because the *rest* of the detail pass is: `ThumbnailRenderer` is AppKit-
// gated, so nothing on Linux asks a file URL what kind it is until Phase 7
// gives that platform its own answer.
#if canImport(AppKit)

    import Foundation
    import Testing

    @testable import SkrepkaCore

    /// Telling a copied folder from a copied file, which only the file system can
    /// do — and saying so when it will not.
    ///
    /// Goes through `CopiedFile` rather than round a shortcut, because that is
    /// the seam production uses: `ThumbnailRenderer` makes one lookup and reads
    /// the kind off it. A test that probed separately would stop describing the
    /// call it is meant to cover.
    @Suite("File URL kind")
    struct FileURLKindTests {
        /// The kind the detail pass would land on for a path, exactly as
        /// `ThumbnailRenderer.details(for:)` derives it — nil for a file system
        /// that would not answer as well as for one that answered without
        /// saying.
        private func kind(at url: URL) -> ClipKind? {
            CopiedFile(at: url).flatMap(FileURLKind.kind(of:))
        }

        @Test("A plain directory is a folder")
        func directoryIsFolder() throws {
            // The bug: Finder writes one `public.file-url` whether the user copied
            // a document or a folder, so every row read "File" and wore a document
            // icon.
            let directory = try Fixtures.makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            #expect(kind(at: directory) == .folder)
        }

        @Test("An application bundle is a file, not a folder")
        func packageIsFile() throws {
            // `.app` is a directory on disk, but Finder shows it as one item and so
            // do we — and a folder would lose its preview, since `.folder` is never
            // sent to the thumbnail maker.
            let bundle = try Fixtures.makePackage(named: "ChatGPT.app")
            defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }

            #expect(kind(at: bundle) == .file)
        }

        @Test("A regular file is a file")
        func regularFileIsFile() throws {
            let url = try Fixtures.writePNG(width: 2, height: 2, named: "shot.png")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            #expect(kind(at: url) == .file)
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

            // Nil at the lookup, before the kind rules are consulted at all —
            // there is nothing for them to read.
            #expect(CopiedFile(at: missing) == nil)
            #expect(kind(at: missing) == nil)
        }
    }

#endif

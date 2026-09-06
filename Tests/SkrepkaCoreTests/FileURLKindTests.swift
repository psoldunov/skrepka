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

        /// The same, for a whole copied selection: one walk, then the kind read
        /// off it — what `ThumbnailRenderer.details(for:)` does for a copy of
        /// several files.
        private func kind(
            at urls: [URL],
            deadline: Duration = FileSelection.deadline
        ) -> ClipKind? {
            FileURLKind.kind(of: CopiedSelection.look(at: urls, deadline: deadline))
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
            // A text file, not a picture: a PNG is an `.imageFile` now, so the
            // fixture that used to stand for "an ordinary file" no longer does.
            let url = try Fixtures.writeTextFile(named: "notes.txt")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            #expect(kind(at: url) == .file)
        }

        @Test("A picture on disk is an image, not a file")
        func imageFileIsImage() throws {
            // The bug: a screenshot copied out of Finder arrives as a
            // `public.file-url`, so the row read "File" beside its own preview.
            let url = try Fixtures.writePNG(width: 2, height: 2, named: "shot.png")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            #expect(kind(at: url) == .imageFile)
        }

        @Test("A selection of pictures is images; a mixed one is files")
        func selectionTakesTheSharedKind() throws {
            let directory = try Fixtures.makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let first = try Fixtures.writePNG(width: 2, height: 2, named: "one.png")
            let second = try Fixtures.writePNG(width: 3, height: 3, named: "two.png")
            let text = try Fixtures.writeTextFile(named: "notes.txt")
            defer {
                for url in [first, second, text] {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                }
            }

            #expect(kind(at: [first, second]) == .imageFile)
            // Three pictures and a spreadsheet are four files: `.file` is the one
            // kind every entry in a mixed selection genuinely is.
            #expect(kind(at: [first, text]) == .file)
            #expect(kind(at: []) == nil)
        }

        @Test("A selection that runs out of budget answers nothing at all")
        func selectionOutOfBudgetIsNil() throws {
            // Not `.file`: nil is what "I could not look" has to mean, because
            // `HistoryStore` writes a refined kind onto an existing row only when
            // one came back. Answering `.file` here downgraded a row already
            // reading "300 Images" the first time that copy was made off a slow
            // volume.
            let url = try Fixtures.writePNG(width: 2, height: 2, named: "shot.png")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            #expect(kind(at: [url], deadline: .zero) == nil)
            #expect(kind(at: [url]) == .imageFile)
        }

        @Test("A selection with a file the disk will not describe answers nothing")
        func partlyUnanswerableSelectionIsNil() throws {
            // The two files left of three agreeing says nothing about the third,
            // which is the same reason `ContentSize` refuses a partial sum.
            let url = try Fixtures.writePNG(width: 2, height: 2, named: "shot.png")
            let directory = url.deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: directory) }
            let missing = directory.appending(path: "gone", directoryHint: .notDirectory)

            #expect(kind(at: [url, missing]) == nil)
            #expect(kind(at: [missing, missing]) == nil)
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

// Fenced to Apple platforms, unlike the type it tests, which compiles anywhere
// and is exercised on Linux by ContentSizeTests.
//
// Not for the package cases: swift-corelibs-foundation does answer
// `.isPackageKey`, and answers `true` for a bare `ChatGPT.app` directory, same
// as Darwin — probed against Swift 6.3 on `aarch64-unknown-linux-gnu` rather
// than assumed. What differs is `.fileSizeKey` on a *directory*: nil on Darwin,
// the directory entry's own size on Linux. `describesFolder` asserts the Darwin
// answer, so this suite is Darwin's. Nothing in production depends on either —
// see `CopiedFile.fileSize`.
#if canImport(AppKit)

    import Foundation
    import Testing

    @testable import SkrepkaCore

    /// The one file-system lookup the detail pass takes, and the two separate
    /// answers read off it.
    ///
    /// `FileURLKindTests` and `ContentSizeTests` each cover one reader in depth.
    /// What is only visible here is the thing merging the two lookups had to
    /// preserve: a *single* probe still answers both questions correctly, for
    /// every shape of path that answers them differently.
    @Suite("Copied file")
    struct CopiedFileTests {
        @Test("One lookup answers both the kind and the size of a plain folder")
        func describesFolder() throws {
            let directory = try Fixtures.makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try Data(repeating: 0x41, count: 700)
                .write(to: directory.appending(path: "a.bin", directoryHint: .notDirectory))

            let file = try #require(CopiedFile(at: directory))
            #expect(file.shape == .folder)
            // A directory has no size of its own; the walk is what produces one.
            #expect(file.fileSize == nil)
            #expect(FileURLKind.kind(of: file) == .folder)
            #expect(ContentSize.byteCount(of: file) == 700)
        }

        @Test("One lookup answers both for an application bundle")
        func describesPackage() throws {
            let bundle = try Fixtures.makePackage(named: "ChatGPT.app")
            defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
            try Data(repeating: 0x41, count: 512)
                .write(to: bundle.appending(path: "payload.bin", directoryHint: .notDirectory))

            // The case the two readers deliberately disagree about: a package is
            // a *file* to the kind rules, so it keeps its icon and its preview,
            // and a *directory* to the measurement, so it reports what Finder
            // reports. Both come off this one lookup, which is why `.package` is
            // its own case rather than a verdict the lookup resolves.
            let file = try #require(CopiedFile(at: bundle))
            #expect(file.shape == .package)
            #expect(FileURLKind.kind(of: file) == .file)
            #expect(ContentSize.byteCount(of: file) == 512)
        }

        @Test("One lookup answers both for a regular file")
        func describesRegularFile() throws {
            let directory = try Fixtures.makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appending(path: "notes.txt", directoryHint: .notDirectory)
            try Data(repeating: 0x41, count: 2048).write(to: url)

            let file = try #require(CopiedFile(at: url))
            #expect(file.shape == .file)
            #expect(file.fileSize == 2048)
            #expect(FileURLKind.kind(of: file) == .file)
            #expect(ContentSize.byteCount(of: file) == 2048)
        }

        /// The three filesystem tests above reach `.folder`, `.package` and
        /// `.file`. Nothing reaches ``CopiedFile/Shape/unknown`` — a lookup that
        /// cannot answer for `.isDirectoryKey` throws rather than returning a
        /// blank, so no real path produces one — and it is the arm the two
        /// readers were shaped to disagree about: `FileURLKind` refuses to guess,
        /// because a wrong kind is a mislabelled row that outlives the copy,
        /// while `ContentSize` falls through to the file branch, because a
        /// missing size is one line the subtitle leaves off. Asserted over the
        /// constructed value, which is the only way that arm is reachable.
        ///
        /// Exhaustive on purpose: a fifth case, or an arm regrouped, has to be
        /// spelled out here as well as in the two `switch`es.
        @Test("Every shape maps to a kind and a size, including the one no disk produces")
        func mapsEveryShape() throws {
            let directory = try Fixtures.makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try Data(repeating: 0x41, count: 64)
                .write(to: directory.appending(path: "a.bin", directoryHint: .notDirectory))
            func described(_ shape: CopiedFile.Shape) -> CopiedFile {
                CopiedFile(url: directory, shape: shape, fileSize: 9)
            }

            #expect(FileURLKind.kind(of: described(.folder)) == .folder)
            #expect(FileURLKind.kind(of: described(.package)) == .file)
            #expect(FileURLKind.kind(of: described(.file)) == .file)
            #expect(FileURLKind.kind(of: described(.unknown)) == nil)

            // The directory is real, so the two shapes that walk it report what
            // is inside rather than the 9 they carry — which is the distinction:
            // `fileSize` is the path's own size and is not what a directory
            // reports.
            #expect(ContentSize.byteCount(of: described(.folder)) == 64)
            #expect(ContentSize.byteCount(of: described(.package)) == 64)
            #expect(ContentSize.byteCount(of: described(.file)) == 9)
            #expect(ContentSize.byteCount(of: described(.unknown)) == 9)
        }

        @Test("A path the file system will not describe yields nothing to read")
        func refusesUnanswerablePath() throws {
            // Deleted since the copy, or on a volume no longer mounted. Both
            // readers reach "nothing to say" from this one nil, which is what
            // lets `ThumbnailRenderer` ask once and stop.
            let directory = try Fixtures.makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            #expect(CopiedFile(at: directory.appending(path: "gone", directoryHint: .notDirectory)) == nil)
        }
    }

#endif

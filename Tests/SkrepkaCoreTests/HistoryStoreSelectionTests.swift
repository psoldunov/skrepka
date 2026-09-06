// Exercises the SwiftData store, like HistoryStoreTests, and the AppKit-gated
// detail pass that draws a selection's icon stack (D-9). The Linux engine's
// share of this behaviour — the file list itself — is pinned by
// HistoryStoringTests, which runs against both.
#if canImport(SwiftData)

    import Foundation
    import Testing

    @testable import SkrepkaCore

    /// What the store makes of a copy holding more than one file: how many it says
    /// it has, what it calls them, and whether all of them come back for the paste.
    @Suite("History store selections")
    @MainActor
    struct HistoryStoreSelectionTests {
        private func makeStore() throws -> HistoryStore {
            try HistoryStore(location: nil, retention: .unlimited)
        }

        /// A selection as the capture rules hand it over: `.file` whatever the files
        /// turn out to be, with the first of them also in the payload.
        private func selectionItem(_ urls: [URL]) -> ClipItem {
            ClipItem(
                kind: .file,
                text: urls.map(\.lastPathComponent).joined(separator: "\n"),
                payload: Fixtures.fileURLPayload(urls[0]),
                fileURLs: urls
            )
        }

        @Test("A copy of several files keeps them all, and says how many")
        func storesEveryFileInASelection() async throws {
            let store = try makeStore()
            let first = try Fixtures.writePNG(width: 8, height: 8, named: "one.png")
            let second = try Fixtures.writePNG(width: 8, height: 8, named: "two.png")
            defer {
                for url in [first, second] {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                }
            }

            await store.capture(selectionItem([first, second]))

            let summary = try #require(store.items.first)
            #expect(summary.fileCount == 2)
            #expect(summary.typeLabel == "2 Images")
            // Both files come back for the paste, not just the one in the payload.
            let contents = try #require(store.contents(for: summary.id))
            #expect(contents.fileURLs == [first, second])
            #expect(contents.payload.fileURL == first)
        }

        @Test("A mixed selection is labelled by what every part of it is")
        func labelsMixedSelectionAsFiles() async throws {
            let store = try makeStore()
            let picture = try Fixtures.writePNG(width: 8, height: 8, named: "one.png")
            let document = try Fixtures.writeTextFile(named: "notes.txt")
            defer {
                for url in [picture, document] {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                }
            }

            await store.capture(selectionItem([picture, document]))

            let summary = try #require(store.items.first)
            #expect(summary.typeLabel == "2 Files")
            // Previewed by its first file all the same — the picture is still worth
            // showing, it just does not describe the document beside it.
            #expect(summary.hasThumbnail)
            #expect(summary.imageSizeText == nil)
        }

        @Test("A row holding one file lists that one file for the paste")
        func singleFileEntryStillListsItsFile() async throws {
            // Nothing has to have been captured as a selection for the paste to find
            // its files: an entry built from a payload alone resolves to the file
            // the payload names.
            let store = try makeStore()
            let url = try Fixtures.writeTextFile(named: "notes.txt")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            await store.capture(
                ClipItem(kind: .file, text: "notes.txt", payload: Fixtures.fileURLPayload(url))
            )

            let summary = try #require(store.items.first)
            #expect(summary.fileCount == 1)
            #expect(summary.typeLabel == "File")
            let contents = try #require(store.contents(for: summary.id))
            #expect(contents.fileURLs == [url])
        }

        @Test("Two selections sharing their first file are two rows")
        func selectionsDoNotCollapseOntoEachOther() async throws {
            // The row the user reported: both copies begin with the same file, and
            // the payload is all the store used to identify them by.
            let store = try makeStore()
            let shared = try Fixtures.writeTextFile(named: "report.txt")
            let january = try Fixtures.writeTextFile(named: "jan.txt")
            let february = try Fixtures.writeTextFile(named: "feb.txt")
            defer {
                for url in [shared, january, february] {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                }
            }

            await store.capture(selectionItem([shared, january]))
            await store.capture(selectionItem([shared, february]))

            #expect(store.items.count == 2)
            let newest = try #require(store.items.first?.id)
            let restored = try #require(store.contents(for: newest))
            #expect(restored.fileURLs == [shared, february])
        }

        @Test("The same selection re-copied in another order still pastes both files")
        func reCopyInAnotherOrderPastesEveryFile() async throws {
            // A selection hashes the same whichever file was clicked first, so the
            // second copy lands on the first copy's row and rewrites its file list
            // — while the payload, written once, still carries the *first* copy's
            // leading file. Pasting by dropping the list's first entry then wrote
            // that file twice and the other never.
            let store = try makeStore()
            let first = try Fixtures.writeTextFile(named: "a.txt")
            let second = try Fixtures.writeTextFile(named: "b.txt")
            defer {
                for url in [first, second] {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                }
            }

            await store.capture(selectionItem([first, second]))
            await store.capture(selectionItem([second, first]))
            #expect(store.items.count == 1)

            let summary = try #require(store.items.first)
            let contents = try #require(store.contents(for: summary.id))
            // What the paste actually writes: item zero's file, then one item each
            // for the rest.
            let pasted = [contents.payload.fileURL].compactMap(\.self) + contents.additionalFileURLs
            #expect(pasted.count == 2)
            #expect(Set(pasted) == Set([first, second]))
        }

        @Test("A copy of several files is stored with a stack of their icons")
        func storesAStackOfIcons() async throws {
            let store = try makeStore()
            let picture = try Fixtures.writePNG(width: 300, height: 200, named: "one.png")
            let document = try Fixtures.writeTextFile(named: "notes.txt")
            defer {
                for url in [picture, document] {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                }
            }

            await store.capture(selectionItem([picture, document]))

            let summary = try #require(store.items.first)
            #expect(summary.hasStackIcons)
            // Read by id, like the preview: the pictures do not travel on the
            // summary, so this is the call the picker's cache makes.
            let icons = store.stackIcons(for: summary.id)
            #expect(icons.count == 2)
            // Front layer first, and each layer is that file's own picture.
            #expect(icons == [picture, document].compactMap(FileIconStack.icon(forFileAt:)))
            #expect(icons[0] != icons[1])
        }

        @Test("A row holding one file gets no stack")
        func singleFileHasNoStack() async throws {
            // A stack of one is a picture with extra steps, and the row already has
            // a way to draw a single file.
            let store = try makeStore()
            let url = try Fixtures.writeTextFile(named: "notes.txt")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            await store.capture(
                ClipItem(kind: .file, text: "notes.txt", payload: Fixtures.fileURLPayload(url))
            )
            let summary = try #require(store.items.first)
            #expect(!summary.hasStackIcons)
            #expect(store.stackIcons(for: summary.id).isEmpty)
        }

        @Test("Re-copying a different selection redraws the stack rather than keeping it")
        func stackFollowsTheFilesTheRowHolds() async throws {
            // The dedupe branch rewrites the file list, so a stack left over from
            // the previous copy would picture files this row no longer holds.
            let store = try makeStore()
            let first = try Fixtures.writeTextFile(named: "a.txt")
            let second = try Fixtures.writePNG(width: 8, height: 8, named: "b.png")
            defer {
                for url in [first, second] {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                }
            }

            await store.capture(selectionItem([first, second]))
            let before = store.stackIcons(for: try #require(store.items.first).id)
            await store.capture(selectionItem([second, first]))

            #expect(store.items.count == 1)
            let after = store.stackIcons(for: try #require(store.items.first).id)
            #expect(after.count == 2)
            // Same two files, the other way round: the front layer swaps.
            #expect(after == before.reversed())
        }

        @Test("A copy too large to name in full still counts and pastes every file")
        func namesAreCappedButFilesAreNot() async throws {
            // Paths that do not exist: nothing here turns on what is at the end of
            // them, and a hundred and twenty real files would only slow the suite.
            let store = try makeStore()
            let urls = (0..<(FileSelection.maximumNamedFiles + 20)).compactMap {
                URL(string: "file:///Users/me/nowhere/file-\($0).txt")
            }

            await store.capture(selectionItem(urls))

            let summary = try #require(store.items.first)
            #expect(summary.fileCount == urls.count)
            #expect(summary.typeLabel == "\(urls.count) Files")
            let contents = try #require(store.contents(for: summary.id))
            #expect(contents.fileURLs == urls)
        }
    }

#endif

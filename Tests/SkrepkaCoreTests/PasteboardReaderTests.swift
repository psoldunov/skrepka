// AppKit-only, like the PasteboardReader it tests. Linux reads its clipboard
// through a separate ClipboardSource conformance in Phase 5.
#if canImport(AppKit)

    import AppKit
    import Foundation
    import Testing

    @testable import SkrepkaCore

    /// Reading the pasteboard items a copy of several files arrives as.
    ///
    /// Built as loose `NSPasteboardItem`s rather than by writing to a real
    /// pasteboard: the general one belongs to whoever is using the machine, and a
    /// test that clears it destroys the clipboard of the person running it.
    @Suite("Pasteboard reader")
    struct PasteboardReaderTests {
        private func item(fileURL: String) -> NSPasteboardItem {
            let item = NSPasteboardItem()
            item.setString(fileURL, forType: NSPasteboard.PasteboardType(PasteboardType.fileURL))
            return item
        }

        @Test("Every item's file is read, not just the first")
        func readsEveryFileURL() {
            // The bug: only `pasteboardItems.first` was ever read, and a copy of
            // three files is three items carrying one file URL each — see
            // `NSPasteboard.h`, which names exactly that shape as the replacement
            // for the deprecated `NSFilenamesPboardType`.
            let items = [
                item(fileURL: "file:///Users/me/one.png"),
                item(fileURL: "file:///Users/me/two.png"),
                item(fileURL: "file:///Users/me/three.png"),
            ]
            #expect(
                PasteboardReader.fileURLs(in: items).map(\.lastPathComponent)
                    == ["one.png", "two.png", "three.png"]
            )
        }

        @Test("An item carrying no file is skipped rather than counted")
        func skipsItemsWithoutFiles() {
            let text = NSPasteboardItem()
            text.setString("hello", forType: NSPasteboard.PasteboardType(PasteboardType.string))
            let items = [item(fileURL: "file:///Users/me/one.png"), text]

            #expect(PasteboardReader.fileURLs(in: items).map(\.lastPathComponent) == ["one.png"])
        }

        @Test("Something that is not a file URL under that type is not a file")
        func skipsNonFileURLs() {
            // Any app may put anything under `public.file-url`, and a row that
            // believed an `https:` URL would send the size and preview passes
            // looking for it on disk.
            let items = [item(fileURL: "https://example.com/one.png"), item(fileURL: "not a url at all")]

            #expect(PasteboardReader.fileURLs(in: items).isEmpty)
        }
    }

#endif

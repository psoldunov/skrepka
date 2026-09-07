// Covers the AppKit thumbnail path. Phase 7, with the GdkPixbuf one.
#if canImport(AppKit)

    import AppKit
    import Foundation
    import Testing

    @testable import SkrepkaCore

    @Suite("Thumbnail maker")
    struct ThumbnailMakerTests {
        private let maker = ThumbnailMaker()

        @Test("Image data on the pasteboard yields a preview at the original's pixel size")
        func previewsRawImageData() throws {
            let payload = ClipPayload(representations: [
                PasteboardType.png: try Fixtures.png(width: 400, height: 200)
            ])

            let preview = try #require(maker.makePreview(from: payload))
            #expect(NSImage(data: preview.thumbnail) != nil)
            #expect(preview.pixelSize == ClipItem.ImageSize(width: 400, height: 200))
        }

        @Test("A copied image file is previewed from the file it points at")
        func previewsReferencedImageFile() throws {
            let url = try Fixtures.writePNG(width: 640, height: 480, named: "shot.png")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            let preview = try #require(maker.makePreview(from: Fixtures.fileURLPayload(url)))
            #expect(NSImage(data: preview.thumbnail) != nil)
            #expect(preview.pixelSize == ClipItem.ImageSize(width: 640, height: 480))
        }

        @Test("The generated thumbnail is bounded by the maximum edge")
        func boundsThumbnailSize() throws {
            let url = try Fixtures.writePNG(width: 2048, height: 1024, named: "wide.png")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            let preview = try #require(maker.makePreview(from: Fixtures.fileURLPayload(url)))
            let rep = try #require(NSImage(data: preview.thumbnail)?.representations.first)
            #expect(rep.pixelsWide <= Int(ThumbnailMaker.maximumEdge))
            #expect(rep.pixelsHigh <= Int(ThumbnailMaker.maximumEdge))
        }

        @Test("A copied non-image file gets no preview")
        func skipsNonImageFile() throws {
            let directory = try Fixtures.makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appending(path: "notes.txt", directoryHint: .notDirectory)
            try Data("not an image".utf8).write(to: url)

            #expect(maker.makePreview(from: Fixtures.fileURLPayload(url)) == nil)
        }

        @Test("A file URL pointing nowhere gets no preview")
        func skipsMissingFile() {
            let url = URL(fileURLWithPath: "/tmp/skrepka-does-not-exist-\(UUID().uuidString).png")
            #expect(maker.makePreview(from: Fixtures.fileURLPayload(url)) == nil)
        }

        @Test("Image data wins over the file URL beside it, so nothing is read off disk")
        func prefersInlineImageDataOverTheFile() throws {
            let url = URL(fileURLWithPath: "/tmp/skrepka-does-not-exist-\(UUID().uuidString).png")
            let payload = ClipPayload(representations: [
                PasteboardType.fileURL: Data(url.absoluteString.utf8),
                PasteboardType.png: try Fixtures.png(width: 120, height: 60),
            ])

            let preview = try #require(maker.makePreview(from: payload))
            #expect(preview.pixelSize == ClipItem.ImageSize(width: 120, height: 60))
        }

        @Test("Text-only content has nothing to preview")
        func skipsText() {
            let payload = ClipPayload(representations: [PasteboardType.string: Data("hello".utf8)])
            #expect(maker.makePreview(from: payload) == nil)
        }

        @Test("An EXIF-rotated photo reports the dimensions it is shown at")
        func reportsOrientedDimensions() throws {
            // Orientation 6 stores the picture landscape and asks a reader for a
            // quarter turn, so 640 × 480 on disk is a 480 × 640 portrait on screen.
            // This is the shape every photo taken on a phone held upright arrives in.
            let url = try Fixtures.writeJPEG(
                width: 640,
                height: 480,
                orientation: 6,
                named: "upright.jpg"
            )
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            let preview = try #require(maker.makePreview(from: Fixtures.fileURLPayload(url)))
            #expect(preview.pixelSize == ClipItem.ImageSize(width: 480, height: 640))

            // And the thumbnail really is portrait, so the subtitle and the picture
            // agree rather than both being wrong in the same direction.
            let rep = try #require(NSImage(data: preview.thumbnail)?.representations.first)
            #expect(rep.pixelsHigh > rep.pixelsWide)
        }

        @Test("An unrotated photo reports its stored dimensions unchanged")
        func leavesUnrotatedDimensionsAlone() throws {
            let url = try Fixtures.writeJPEG(
                width: 640,
                height: 480,
                orientation: 1,
                named: "level.jpg"
            )
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            let preview = try #require(maker.makePreview(from: Fixtures.fileURLPayload(url)))
            #expect(preview.pixelSize == ClipItem.ImageSize(width: 640, height: 480))
        }

        @Test("A copied folder gets no preview")
        func skipsDirectory() throws {
            let directory = try Fixtures.makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            #expect(maker.makePreview(from: Fixtures.fileURLPayload(directory)) == nil)
        }

        // MARK: - Bytes only

        /// The whole reason ``ThumbnailMaker/makePreview(fromImageBytesIn:)``
        /// exists: content learned from a peer carries a `public.file-url` naming
        /// a path on the machine that made the copy, and this machine may well
        /// have an unrelated file sitting at it. Drawing that file as the row's
        /// picture is the failure being prevented, so the same payload has to
        /// answer differently through the two entry points.
        @Test("A payload naming a file is previewed by one entry point and not the other")
        func drawsNothingFromAFileThePayloadOnlyNames() throws {
            let url = try Fixtures.writePNG(width: 640, height: 480, named: "peer.png")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let payload = Fixtures.fileURLPayload(url)

            #expect(maker.makePreview(fromImageBytesIn: payload) == nil)
            #expect(maker.makePreview(from: payload) != nil)
        }

        @Test("Image bytes are previewed without the file fallback")
        func drawsImageBytes() throws {
            let payload = ClipPayload(representations: [
                PasteboardType.png: try Fixtures.png(width: 400, height: 200)
            ])

            let preview = try #require(maker.makePreview(fromImageBytesIn: payload))
            #expect(preview.pixelSize == ClipItem.ImageSize(width: 400, height: 200))
        }

        /// A type that decodes and will not scale must not hide the one behind
        /// it. The loop used to leave on the first such failure, so an image
        /// `NSImage` accepts and cannot draw suppressed a perfectly good one
        /// ranked below it.
        ///
        /// The payload is deliberately mislabelled, because that is the only way
        /// to reach the case: the types are tried in a fixed order — png, tiff,
        /// pdf — and nothing `Fixtures` can write under the first of them decodes
        /// without also drawing. `NSImage(data:)` sniffs the bytes rather than
        /// trusting the pasteboard type, so an empty-canvas PDF filed under
        /// `public.png` stands in for exactly what this guards: the earlier type
        /// decoded, produced nothing drawable, and must hand on rather than end
        /// the search.
        @Test("A type that will not scale does not hide the one behind it")
        func fallsThroughToTheNextImageType() throws {
            let payload = ClipPayload(representations: [
                PasteboardType.png: Self.emptyPDF,
                PasteboardType.tiff: try Fixtures.png(width: 40, height: 20),
            ])
            // The stand-in has to decode *and* refuse to scale, or this proves
            // nothing. Both are asserted, because only the first is anything the
            // fixture controls: it will not scale because a zero media box gives
            // `NSImage` a zero size, which is Core Graphics behaviour rather than
            // a documented promise. Should CG ever give that page a default size
            // instead, this fails as the dead fixture it has become rather than
            // as a regression in the loop below.
            #expect(NSImage(data: Self.emptyPDF) != nil)
            #expect(
                maker.makePreview(
                    from: ClipPayload(representations: [PasteboardType.png: Self.emptyPDF])
                ) == nil
            )

            let preview = try #require(maker.makePreview(fromImageBytesIn: payload))
            #expect(preview.pixelSize == ClipItem.ImageSize(width: 40, height: 20))
        }

        /// A one-page PDF whose media box is empty, written by hand because no
        /// fixture makes one: `CGPDFContext` refuses a zero-sized page.
        private static let emptyPDF: Data = {
            let data = NSMutableData()
            guard let consumer = CGDataConsumer(data: data) else { return Data() }
            var box = CGRect.zero
            guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
                return Data()
            }
            context.beginPDFPage(nil)
            context.endPDFPage()
            context.closePDF()
            return data as Data
        }()
    }

#endif

// Not in `HistoryStoringTests`, which asserts what every engine must agree on:
// a thumbnail is macOS-only until `ThumbnailMaker` has a second conformance
// (D-9, Phase 7), so the SQLite engine would fail every case here for a reason
// that is not a defect. Fenced to SwiftData with the store it drives.
#if canImport(SwiftData)

    import AppKit
    import Foundation
    import SkrepkaSync
    import Testing

    @testable import SkrepkaCore

    /// A row learned from a peer draws its own picture.
    ///
    /// No thumbnail crosses the wire — `SyncClipMeta` carries a text preview and
    /// dimensions, and `SyncMetaMapping.makeRecord` leaves `thumbnailData` nil —
    /// and the local detail pass never sees content a peer sent. So the arriving
    /// bytes are the only chance a synced picture has of being drawn, and without
    /// it the picker shows a kind symbol on a text-height row: `ThumbnailCache`
    /// asks `ClipSummary.hasThumbnail` before it asks for anything to draw.
    @Suite("History store sync thumbnails")
    @MainActor
    struct HistoryStoreSyncThumbnailTests {
        @Test("A picture pushed with its bytes is drawn")
        func capturesAThumbnailForAPictureThatArrivedInline() async throws {
            let store = try SyncFixtures.makeStore()
            let png = try Self.imageBytes()

            try await store.capture(Self.imageMeta(png), payloads: [Self.pngKey: png])

            let summary = try #require(store.items.first)
            #expect(summary.hasThumbnail)
            #expect(store.thumbnail(for: summary.id) != nil)
        }

        /// The lazy half of design §7 is the case that matters: most pictures are
        /// over `SyncLimits.livePushInlineLimit`, so they land as metadata alone
        /// and their bytes arrive on a later exchange. The row has to gain its
        /// picture then, not stay a symbol for ever.
        ///
        /// Drawn at 400 × 200, over ``ThumbnailMaker/maximumEdge``, so the scaling
        /// branch runs on this path rather than only on the local one.
        @Test("A picture fetched after the row was learned is drawn then")
        func backfillsAThumbnailWhenTheBytesArriveLater() async throws {
            let store = try SyncFixtures.makeStore()
            let png = try Self.imageBytes(width: 400, height: 200)
            let meta = Self.imageMeta(png, width: 400, height: 200)

            try await store.capture(meta, payloads: [:])
            #expect(try #require(store.items.first).hasThumbnail == false)

            try await store.capture(meta, payloads: [Self.pngKey: png])

            let summary = try #require(store.items.first)
            #expect(summary.hasThumbnail)
            let thumbnail = try #require(store.thumbnail(for: summary.id))
            let edge = try #require(NSImage(data: thumbnail)?.representations.first)
            #expect(edge.pixelsWide <= Int(ThumbnailMaker.maximumEdge))
        }

        /// `ThumbnailRenderer.details(for:)` gates the local pass on
        /// ``ClipKind/canPreview``, and the sync path has to gate on the same
        /// thing or two paired Macs draw one clipping differently.
        ///
        /// Ordinary rather than contrived: `PasteboardType.readOrder` ranks `rtf`
        /// and `html` above the image types, `CaptureRules.kind(for:)` takes the
        /// first present, and `PasteboardReader` keeps every flavour it finds — so
        /// a rich-text clipping carrying a PNG is what a copy out of a mail client
        /// looks like. It draws no picture locally and must draw none here.
        @Test("Rich text carrying image bytes draws no picture, as it does not locally")
        func drawsNoPictureForAKindThatCannotPreview() async throws {
            let store = try SyncFixtures.makeStore()
            let png = try Self.imageBytes()
            let rtf = Data("{\\rtf1 hello}".utf8)
            let meta = Self.meta(
                kind: .richText,
                contentHash: ClipItem.hash(
                    kind: .richText,
                    text: "hello",
                    payload: ClipPayload(representations: [:]),
                    fileURLs: []
                )
            )

            try await store.capture(
                meta,
                payloads: [Self.pngKey: png, Self.richTextKey: rtf]
            )

            #expect(try #require(store.items.first).hasThumbnail == false)
        }

        /// A row is a snapshot of the copy that made it. A peer filling in a
        /// representation this machine did not hold must not repaint the picture
        /// the machine drew for itself — and the fill itself still has to happen,
        /// or this asserts nothing.
        @Test("A peer's bytes fill the row without repainting a picture it already had")
        func leavesAThumbnailThisMachineDrewAlone() async throws {
            let store = try SyncFixtures.makeStore()
            let png = try Self.imageBytes()
            #expect(await store.capture(Self.imageItem(png)))
            let local = try #require(store.items.first)
            let drawn = try #require(store.thumbnail(for: local.id))

            // Same content, so the same `contentHash` — `.image` hashes the
            // richest ranked representation, which is the PNG either way — plus a
            // representation this machine has no bytes for.
            try await store.capture(
                Self.imageMeta(png),
                payloads: [Self.pngKey: png, Self.tiffKey: png]
            )

            let summary = try #require(store.items.first)
            #expect(store.thumbnail(for: summary.id) == drawn)
            // The fill happened, so the untouched picture means the guard held
            // rather than that nothing ran.
            #expect(store.contents(for: summary.id)?.payload.data(forType: PasteboardType.tiff) != nil)
        }

        /// The dimensions a peer sent survive a picture drawn from a PDF, which
        /// is the one representation that used to cost them.
        ///
        /// `NSPDFImageRep` reports having no pixels as `0` rather than by
        /// refusing, so ``ThumbnailMaker/pixelSize(of:)`` measured a PDF at
        /// `0 × 0` — a real value, and coalescing cannot decline one. A row
        /// learned as `2560 × 1440` read `0 × 0` from the moment its picture
        /// landed, and permanently: the thumbnail is set by then, so the guard in
        /// ``HistoryStore/backfillPreview(_:into:)`` stops a later round carrying
        /// the PNG from putting it right.
        ///
        /// A round that carries an item's PDF and not its PNG is ordinary rather
        /// than contrived. `SyncExchange.fetchPayloads` spends one
        /// `PeerLink.payloadBudgetPerSync` across every item it fetches and stops
        /// mid-item when it runs out, which is what a first sync against a
        /// picture-heavy peer looks like.
        @Test("A picture drawn from a PDF keeps the dimensions the peer sent")
        func keepsPeerDimensionsWhenOnlyThePDFArrives() async throws {
            let store = try SyncFixtures.makeStore()
            let pdf = try Fixtures.pdf(width: 200, height: 100)
            let meta = Self.meta(
                kind: .image,
                contentHash: ClipItem.hash(
                    kind: .image,
                    text: "Image",
                    payload: ClipPayload(representations: [PasteboardType.pdf: pdf]),
                    fileURLs: []
                ),
                width: 2560,
                height: 1440,
                representations: [RepresentationDescriptor(key: Self.pdfKey, byteCount: pdf.count)]
            )

            try await store.capture(meta, payloads: [:])
            try await store.capture(meta, payloads: [Self.pdfKey: pdf])

            let summary = try #require(store.items.first)
            // The picture landed, so surviving dimensions mean the coalescing
            // held rather than that nothing was drawn.
            #expect(summary.hasThumbnail)
            #expect(summary.imageSize == ClipItem.ImageSize(width: 2560, height: 1440))
        }

        @Test("Text learned from a peer draws no picture")
        func drawsNoThumbnailForText() async throws {
            let store = try SyncFixtures.makeStore()

            try await store.capture(
                SyncFixtures.meta("plain words"),
                payloads: [Self.plainTextKey: Data("plain words".utf8)]
            )

            #expect(try #require(store.items.first).hasThumbnail == false)
        }

        /// Bytes arriving for a row that holds none, where none of them is a
        /// picture: the fill has to land and the row has to stay a text row.
        @Test("Text bytes fetched later fill the row and draw nothing")
        func fillsATextRowWithoutDrawingAnything() async throws {
            let store = try SyncFixtures.makeStore()
            let meta = SyncFixtures.meta("plain words")

            try await store.capture(meta, payloads: [:])
            try await store.capture(meta, payloads: [Self.plainTextKey: Data("plain words".utf8)])

            let summary = try #require(store.items.first)
            #expect(summary.hasThumbnail == false)
            #expect(store.contents(for: summary.id)?.payload.data(forType: PasteboardType.string) != nil)
        }

        // MARK: - Fixtures

        private static let pngKey = RepresentationKey(
            canonical: "image/png",
            origin: PasteboardType.png
        )
        private static let tiffKey = RepresentationKey(
            canonical: "image/tiff",
            origin: PasteboardType.tiff
        )
        private static let pdfKey = RepresentationKey(
            canonical: "application/pdf",
            origin: PasteboardType.pdf
        )
        private static let richTextKey = RepresentationKey(
            canonical: "text/rtf",
            origin: PasteboardType.rtf
        )
        private static let plainTextKey = RepresentationKey(
            canonical: "text/plain;charset=utf-8",
            origin: PasteboardType.string
        )
        private static let epoch = Date(timeIntervalSince1970: 1_000_000)

        /// A function rather than a `static let`: a stored property cannot throw,
        /// so it would have to swallow the error and surface an ImageIO failure as
        /// a bare nil at whichever `#require` reached it first.
        private static func imageBytes(width: Int = 40, height: Int = 20) throws -> Data {
            try Fixtures.png(width: width, height: height)
        }
        private static func imageItem(_ png: Data) -> ClipItem {
            ClipItem(
                kind: .image,
                text: "Image",
                payload: ClipPayload(representations: [PasteboardType.png: png]),
                createdAt: epoch
            )
        }

        /// The same picture as a peer describes it: dimensions and a text preview,
        /// and not one byte of the image.
        private static func imageMeta(_ png: Data, width: Int = 40, height: Int = 20) -> SyncClipMeta {
            meta(
                kind: .image,
                contentHash: imageItem(png).contentHash,
                width: width,
                height: height,
                representations: [RepresentationDescriptor(key: pngKey, byteCount: png.count)]
            )
        }

        private static func meta(
            kind: ClipKind,
            contentHash: String,
            width: Int? = nil,
            height: Int? = nil,
            representations: [RepresentationDescriptor] = []
        ) -> SyncClipMeta {
            SyncClipMeta(
                contentHash: contentHash,
                kind: kind.rawValue,
                preview: "Image",
                createdAt: epoch,
                isPinned: LWWRegister(
                    value: false,
                    timestamp: epoch,
                    deviceID: SyncFixtures.peerDevice
                ),
                imageWidth: width,
                imageHeight: height,
                originDeviceID: SyncFixtures.peerDevice,
                representations: representations
            )
        }
    }

#endif

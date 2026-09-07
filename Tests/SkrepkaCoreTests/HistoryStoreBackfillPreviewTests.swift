// Split from `HistoryStoreSyncThumbnailTests`, which drives whole `capture`
// rounds: these two assert the rule itself, against a `ClipRecord` built by
// hand, because the store path cannot distinguish either rule from its absence
// — identity is `contentHash`, so a re-render there runs over the same bytes and
// produces the same picture and the same dimensions. Fenced to SwiftData with
// the record they build.
#if canImport(SwiftData)

    import Foundation
    import SkrepkaSync
    import Testing

    @testable import SkrepkaCore

    /// What ``HistoryStore/backfillPreview(_:into:)`` will and will not overwrite.
    ///
    /// Two rules, and each protects something the row already holds: the picture
    /// it was stored with, and the dimensions it was told before any bytes
    /// arrived.
    @Suite("History store preview backfill")
    @MainActor
    struct HistoryStoreBackfillPreviewTests {
        @Test("A picture already drawn is never replaced")
        func keepsAPictureTheRowAlreadyHas() throws {
            let store = try SyncFixtures.makeStore()
            let record = Self.record(thumbnail: Data("drawn here".utf8))

            store.backfillPreview(
                ThumbnailMaker.Preview(
                    thumbnail: Data("sent by a peer".utf8),
                    pixelSize: ClipItem.ImageSize(width: 8, height: 8)
                ),
                into: record
            )

            #expect(record.thumbnailData == Data("drawn here".utf8))
            #expect(record.imageWidth == 2560)
        }

        /// The dimensions a peer sent are what the row's subtitle reads before any
        /// bytes arrive, and drawing the picture must not cost them. A render can
        /// produce a thumbnail and no pixel size at all, which is why
        /// `backfillPreview` coalesces rather than assigns.
        ///
        /// Coalescing only answers a *missing* measurement, which is why
        /// ``ThumbnailMaker/pixelSize(of:)`` has to report one as nil rather than
        /// as zero — see `HistoryStoreSyncThumbnailTests` for the PDF that used to
        /// arrive measured `0 × 0` and walk straight past this rule.
        @Test("Drawing a picture keeps dimensions the render could not measure")
        func keepsDimensionsARenderCouldNotMeasure() throws {
            let store = try SyncFixtures.makeStore()
            let record = Self.record(thumbnail: nil)

            store.backfillPreview(
                ThumbnailMaker.Preview(thumbnail: Data("drawn".utf8), pixelSize: nil),
                into: record
            )

            #expect(record.thumbnailData == Data("drawn".utf8))
            #expect(record.imageWidth == 2560)
            #expect(record.imageHeight == 1440)
        }

        // MARK: - Fixtures

        /// A row that already knows its dimensions and may or may not have drawn
        /// its picture — the two states ``HistoryStore/backfillPreview(_:into:)``
        /// tells apart.
        private static func record(thumbnail: Data?) -> ClipRecord {
            ClipRecord(
                id: UUID(),
                kindRaw: ClipKind.image.rawValue,
                text: "Image",
                sourceBundleID: nil,
                createdAt: Date(timeIntervalSince1970: 1_000_000),
                isPinned: false,
                isConcealed: false,
                contentHash: "a-picture",
                imageWidth: 2560,
                imageHeight: 1440,
                byteCount: nil,
                thumbnailData: thumbnail,
                payloadData: Data()
            )
        }
    }

#endif

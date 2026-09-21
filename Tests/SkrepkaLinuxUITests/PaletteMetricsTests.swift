import Foundation
import SkrepkaCore
import Testing

@testable import SkrepkaLinuxUI

/// The palette's fit on the screen it opens on.
///
/// Pinned because the failure is invisible from a Mac: the metrics were drawn
/// for a laptop display, the Linux test rig is a Steam Deck at **1280×800**,
/// and a palette that is 40 pixels too tall there is clipped rather than
/// scrolled. Nothing in a view test would notice.
@Suite("Palette metrics")
struct PaletteMetricsTests {
    /// The Deck in Desktop Mode, which is the screen Phase 7 is written
    /// against.
    private static let deckHeight: Int32 = 800

    private static func rows(_ count: Int, hasThumbnail: Bool = false) -> [ClipSummary] {
        (0..<count).map { index in
            ClipSummary(
                id: UUID(),
                kind: .text,
                text: "clip \(index)",
                sourceBundleID: nil,
                createdAt: Date(timeIntervalSince1970: 0),
                isPinned: false,
                isConcealed: false,
                imageSize: nil,
                byteCount: nil,
                hasThumbnail: hasThumbnail
            )
        }
    }

    @Test("A long history never grows past two thirds of the screen")
    func longHistoryIsCappedByTheScreen() {
        let height = PaletteMetrics.height(rows: Self.rows(200), outputHeight: Self.deckHeight)
        #expect(height <= Int32(Double(Self.deckHeight) * PaletteMetrics.maximumScreenFraction))
        #expect(height <= PaletteMetrics.maximumHeight)
    }

    @Test("On the Deck the screen binds before the Mac's maximum")
    func theDeckIsTheBindingConstraint() {
        // 800 × 2/3 = 533, which is under the Mac's 540. If this ever inverts,
        // the cap has stopped doing anything on the one machine it was added
        // for.
        #expect(PaletteMetrics.ceiling(outputHeight: Self.deckHeight) < PaletteMetrics.maximumHeight)
    }

    @Test("On a tall desktop the fixed maximum binds instead")
    func aTallScreenDoesNotGrowThePalette() {
        // The cap exists to stop a small screen being swallowed, not to make
        // the palette bigger on a large one.
        #expect(PaletteMetrics.ceiling(outputHeight: 2160) == PaletteMetrics.maximumHeight)
    }

    @Test("An unknown screen falls back to the Mac's maximum")
    func unknownOutputUsesTheFixedMaximum() {
        // GDK reports 0 before the display is open, and a daemon that starts
        // before its compositor sees exactly that.
        #expect(PaletteMetrics.ceiling(outputHeight: 0) == PaletteMetrics.maximumHeight)
    }

    @Test("A screen too small for the minimum still gets the minimum")
    func absurdlySmallScreensGetTheMinimum() {
        // A palette shorter than its own chrome is not a smaller palette.
        #expect(PaletteMetrics.ceiling(outputHeight: 100) == PaletteMetrics.minimumHeight)
    }

    @Test("An empty history is the minimum height, not zero")
    func emptyHistoryHasAHeight() {
        let height = PaletteMetrics.height(rows: [], outputHeight: Self.deckHeight)
        #expect(height >= PaletteMetrics.minimumHeight)
        #expect(height <= PaletteMetrics.ceiling(outputHeight: Self.deckHeight))
    }

    @Test("A few rows size to their content rather than to the cap")
    func shortHistoriesShrink() {
        let short = PaletteMetrics.height(rows: Self.rows(2), outputHeight: Self.deckHeight)
        let long = PaletteMetrics.height(rows: Self.rows(50), outputHeight: Self.deckHeight)
        #expect(short < long)
        #expect(short >= PaletteMetrics.minimumHeight)
    }

    @Test("Picture rows are taller than text rows")
    func pictureRowsAreTaller() {
        let text = PaletteMetrics.height(rows: Self.rows(3), outputHeight: 0)
        let pictures = PaletteMetrics.height(
            rows: Self.rows(3, hasThumbnail: true), outputHeight: 0)
        #expect(pictures > text)
    }

    // MARK: - Placement

    @Test("On the Deck the panel hangs 18% down, centred across")
    func deckPlacementMatchesTheMac() {
        let frame = PaletteMetrics.frame(wantedHeight: 300, outputWidth: 1280, outputHeight: Self.deckHeight)
        #expect(frame == PaletteFrame(x: 310, y: 144, width: PaletteMetrics.width, height: 300))
    }

    @Test("The top edge stays put while a query shrinks the list")
    func theTopDoesNotMoveWithTheContent() {
        // The search field sits at the top of the panel, so a top that moved
        // with the height would slide the field out from under the caret on
        // every keystroke that narrows the list.
        let full = PaletteMetrics.frame(wantedHeight: 520, outputWidth: 1280, outputHeight: Self.deckHeight)
        let narrowed = PaletteMetrics.frame(
            wantedHeight: 180, outputWidth: 1280, outputHeight: Self.deckHeight)
        #expect(full.y == narrowed.y)
    }

    @Test("A long history never runs off the bottom of the screen")
    func theTallestPanelFits() {
        for height: Int32 in [300, 600, 800, 1080, 2160] {
            let frame = PaletteMetrics.frame(wantedHeight: 10_000, outputWidth: 1920, outputHeight: height)
            #expect(frame.y >= 0)
            #expect(frame.y + frame.height <= height)
        }
    }

    @Test("A Deck docked to a 4K screen places against the big screen")
    func aDockedDeckUsesTheScreenItOpensOn() {
        let frame = PaletteMetrics.frame(wantedHeight: 400, outputWidth: 3840, outputHeight: 2160)
        #expect(frame == PaletteFrame(x: 1590, y: 388, width: PaletteMetrics.width, height: 400))
    }

    @Test("A screen narrower than the panel gets a panel as wide as the screen")
    func narrowScreensClampTheWidth() {
        let frame = PaletteMetrics.frame(wantedHeight: 300, outputWidth: 480, outputHeight: Self.deckHeight)
        #expect(frame.x == 0)
        #expect(frame.width == 480)
    }

    @Test("An output not yet known places at the origin with the Mac's limits")
    func unknownOutputPlacesAtTheOrigin() {
        let frame = PaletteMetrics.frame(wantedHeight: 10_000, outputWidth: 0, outputHeight: 0)
        #expect(
            frame
                == PaletteFrame(x: 0, y: 0, width: PaletteMetrics.width, height: PaletteMetrics.maximumHeight)
        )
    }

    @Test("A near-empty list still gets the minimum height")
    func placementRespectsTheMinimum() {
        let frame = PaletteMetrics.frame(wantedHeight: 20, outputWidth: 1280, outputHeight: Self.deckHeight)
        #expect(frame.height == PaletteMetrics.minimumHeight)
    }

    @Test("A panel that measures smaller than its frame keeps the frame")
    func fitLeavesARoomyFrameAlone() {
        let frame = PaletteMetrics.frame(wantedHeight: 300, outputWidth: 1280, outputHeight: Self.deckHeight)
        let fitted = PaletteMetrics.fit(
            frame, minimumWidth: 400, minimumHeight: 120, outputWidth: 1280, outputHeight: Self.deckHeight)
        #expect(fitted == frame)
    }

    @Test("A panel wider than a narrow output grows to its minimum and starts at the left")
    func fitGrowsPastANarrowOutput() {
        let frame = PaletteMetrics.frame(wantedHeight: 300, outputWidth: 480, outputHeight: Self.deckHeight)
        let fitted = PaletteMetrics.fit(
            frame, minimumWidth: 560, minimumHeight: 120, outputWidth: 480, outputHeight: Self.deckHeight)
        #expect(fitted.width == 560)
        #expect(fitted.x == 0)
    }

    @Test("A panel taller than the cap moves up rather than off the bottom")
    func fitKeepsATallPanelOnScreen() {
        let frame = PaletteMetrics.frame(wantedHeight: 10_000, outputWidth: 1280, outputHeight: 300)
        let fitted = PaletteMetrics.fit(
            frame, minimumWidth: 400, minimumHeight: 280, outputWidth: 1280, outputHeight: 300)
        #expect(fitted.height == 280)
        #expect(fitted.y + fitted.height <= 300)
    }

    @Test("A concealed picture row stays short")
    func concealedRowsStayShort() {
        // Concealed entries draw no preview, so a tall row would be empty space
        // announcing that something is hidden there.
        let concealed = ClipSummary(
            id: UUID(),
            kind: .text,
            text: "",
            sourceBundleID: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            isPinned: false,
            isConcealed: true,
            imageSize: nil,
            byteCount: nil,
            hasThumbnail: true
        )
        #expect(PaletteMetrics.rowHeight(for: concealed) == PaletteMetrics.standardRowHeight)
    }
}

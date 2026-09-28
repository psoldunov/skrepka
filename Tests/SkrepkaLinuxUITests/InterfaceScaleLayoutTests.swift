import Foundation
import Testing

@testable import SkrepkaLinuxUI

/// The picker, the Settings window and the thumbnails at an interface size
/// other than the design size: the pieces that must agree with each other
/// for the interface to grow as one drawing.
@Suite("Interface size: layout")
struct InterfaceScaleLayoutTests {
    private static func metrics(_ percent: Int) throws -> PaletteMetrics {
        PaletteMetrics(scale: try #require(InterfaceScale(percent: percent)))
    }

    @Test("the design size is the Mac's sizes, unchanged")
    func standardIsTheMac() {
        let metrics = PaletteMetrics.standard
        #expect(metrics.width == 660)
        #expect(metrics.maximumHeight == 540)
        #expect(metrics.minimumHeight == 150)
        #expect(metrics.standardRowHeight == 46)
        #expect(metrics.imageRowHeight == 64)
        #expect(metrics.chromeHeight == 50 + 34 + 2)
        #expect(metrics.previewSize.width == 84 && metrics.previewSize.height == 48)
    }

    @Test("a larger size grows the panel, its rows and its chrome together")
    func everythingGrows() throws {
        let metrics = try Self.metrics(150)
        #expect(metrics.width == 990)
        #expect(metrics.standardRowHeight == 69)
        #expect(metrics.imageRowHeight == 96)
        // The separators are hairlines and stay one pixel each.
        #expect(metrics.chromeHeight == 75 + 51 + 2)
        #expect(metrics.previewSize.width == 126 && metrics.previewSize.height == 72)
    }

    @Test("the panel wants the sum of its rows at the size they are drawn at")
    func wantedHeightAddsUp() throws {
        let metrics = try Self.metrics(125)
        let rows = [metrics.rowHeight(isImage: false), metrics.rowHeight(isImage: true)]
        #expect(
            metrics.wantedHeight(rowHeights: rows)
                == metrics.chromeHeight + metrics.standardRowHeight + metrics.imageRowHeight + metrics.gutter)
    }

    @Test("on the Deck the screen still binds, however large the interface")
    func theDeckStillBinds() throws {
        // 800 × 2/3 = 533, under the maximum at every size.
        for percent in InterfaceScale.choices {
            #expect(try Self.metrics(percent).ceiling(outputHeight: 800) == 533)
        }
    }

    @Test("a panel wider than the screen is as wide as the screen")
    func aWidePanelFitsTheScreen() throws {
        let frame = try Self.metrics(200).frame(wantedHeight: 300, outputWidth: 1280, outputHeight: 800)
        #expect(frame.x == 0)
        #expect(frame.width == 1280)
    }

    @Test("the gap rules a larger size adds stay inside the Settings window")
    func settingsGapsAreScoped() throws {
        let scale = try #require(InterfaceScale(percent: 175))
        let css = SettingsStyle.css(isDark: true, accent: "rgb(1,2,3)", scale: scale)
        #expect(css.contains("window.skrepka-settings .skrepka-gap-12 { border-spacing: 9px; }"))
        for selector in StylesheetTests.leadingSelectors(css) {
            let scoped =
                selector.hasPrefix("window.skrepka-settings") || selector.hasPrefix(".skrepka-")
                || selector.hasPrefix("list.skrepka-")
            #expect(scoped, "unscoped selector: \(selector)")
        }
    }

    @Test("the picker's plain-window margin grows with the stylesheet that draws it")
    func plainInsetAgrees() throws {
        let scale = try #require(InterfaceScale(percent: 125))
        let css = PickerStyle.css(isDark: true, accent: "rgb(1,2,3)", scale: scale)
        #expect(css.contains("margin: \(scale.length(PickerStyle.plainInset))px;"))
        #expect(css.contains("window.skrepka-picker .skrepka-gap-11 { border-spacing: 3px; }"))
    }

    @Test(
        "Settings opens at its design size unless the interface is larger",
        arguments: [0, 700, 800, 2160] as [Int32])
    func settingsDesignSize(screenHeight: Int32) {
        let size = SettingsWindow.defaultSize(at: .standard, screen: (screenHeight * 16 / 10, screenHeight))
        #expect(size.width == 900)
        #expect(size.height == 660)
    }

    @Test("a larger Settings window stays inside the screen")
    func settingsFitsTheScreen() throws {
        let scale = try #require(InterfaceScale(percent: 150))
        // Five sixths of the Deck's 1280×800.
        let deck = SettingsWindow.defaultSize(at: scale, screen: (1280, 800))
        #expect(deck.width == 1066)
        #expect(deck.height == 666)
        let fourK = SettingsWindow.defaultSize(at: scale, screen: (3840, 2160))
        #expect(fourK.width == 1350)
        #expect(fourK.height == 990)
        let unknown = SettingsWindow.defaultSize(at: scale, screen: (0, 0))
        #expect(unknown.width == 1350)
        #expect(unknown.height == 990)
    }

    @Test("thumbnails decode for the preview at the size in force, and not the one before")
    func thumbnailsFollowTheSize() throws {
        let cache = ThumbnailCache()
        _ = try #require(cache.store(hash: "before", data: ThumbnailCacheTests.largePNG))
        cache.resize(for: try Self.metrics(150))
        #expect(!cache.contains("before"))
        #expect(cache.box == PixelSize(width: 126, height: 72))
        let texture = try #require(cache.store(hash: "after", data: ThumbnailCacheTests.largePNG))
        #expect(
            ThumbnailCacheTests.size(of: texture)
                == ThumbnailSizing.loaderSize(source: PixelSize(width: 800, height: 480), box: cache.box))
    }

    @Test("resizing to the size in force keeps what is cached")
    func sameSizeKeepsTheCache() throws {
        let cache = ThumbnailCache()
        _ = try #require(cache.store(hash: "kept", data: ThumbnailCacheTests.largePNG))
        cache.resize(for: .standard)
        #expect(cache.contains("kept"))
    }
}

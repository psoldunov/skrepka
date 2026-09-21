import Foundation
import Testing

@testable import SkrepkaLinuxUI

/// The small pure pieces the picker's view layer leans on: relative age, byte
/// sizes, thumbnail decode bounds, the LRU eviction order, and the icon chains.
struct PickerRelativeTimeTests {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    @Test func picksTheLargestFittingUnit() {
        #expect(RelativeTime.string(from: epoch, to: epoch.addingTimeInterval(1)) == "1 second ago")
        #expect(RelativeTime.string(from: epoch, to: epoch.addingTimeInterval(10)) == "10 seconds ago")
        #expect(RelativeTime.string(from: epoch, to: epoch.addingTimeInterval(90)) == "1 minute ago")
        #expect(RelativeTime.string(from: epoch, to: epoch.addingTimeInterval(3700)) == "1 hour ago")
    }

    @Test func subSecondReadsNow() {
        #expect(RelativeTime.string(from: epoch, to: epoch.addingTimeInterval(0.4)) == "now")
    }

    @Test func futureReadsForward() {
        #expect(RelativeTime.string(from: epoch, to: epoch.addingTimeInterval(-30)) == "in 30 seconds")
    }
}

struct DecimalByteCountTests {
    @Test func singularAndPlural() {
        #expect(DecimalByteCount.string(1) == "1 byte")
        #expect(DecimalByteCount.string(512) == "512 bytes")
    }

    @Test func decimalUnits() {
        #expect(DecimalByteCount.string(1000) == "1 KB")
        #expect(DecimalByteCount.string(1500) == "1.5 KB")
        #expect(DecimalByteCount.string(2_400_000) == "2.4 MB")
    }
}

struct ThumbnailSizingTests {
    @Test func scalesLargePicturesToCover() {
        let size = ThumbnailSizing.loaderSize(
            source: PixelSize(width: 1000, height: 500), box: PixelSize(width: 84, height: 48))
        #expect(size.width >= 84 && size.height >= 48)
        #expect(size.width < 1000)
    }

    @Test func leavesSmallPicturesAlone() {
        let source = PixelSize(width: 40, height: 40)
        #expect(ThumbnailSizing.loaderSize(source: source, box: PixelSize(width: 84, height: 48)) == source)
    }

    @Test func toleratesZero() {
        let source = PixelSize(width: 0, height: 0)
        #expect(ThumbnailSizing.loaderSize(source: source, box: PixelSize(width: 84, height: 48)) == source)
    }
}

struct PickerLRUCacheTests {
    @Test func evictsColdestAndReportsIt() {
        var cache = LRUCache<Int>(capacity: 2)
        #expect(cache.insert("a", 1).isEmpty)
        #expect(cache.insert("b", 2).isEmpty)
        #expect(cache.insert("c", 3) == [1])
        #expect(cache.keysByAge == ["b", "c"])
    }

    @Test func replacementReportsOldValue() {
        var cache = LRUCache<Int>(capacity: 2)
        _ = cache.insert("a", 1)
        #expect(cache.insert("a", 2) == [1])
        #expect(cache.take("a") == 2)
    }

    @Test func takingPromotes() {
        var cache = LRUCache<Int>(capacity: 2)
        _ = cache.insert("a", 1)
        _ = cache.insert("b", 2)
        #expect(cache.take("a") == 1)
        #expect(cache.insert("c", 3) == [2])
        #expect(cache.contains("a"))
        #expect(!cache.contains("b"))
    }
}

struct PickerIconNameTests {
    @Test func concealedOverridesKind() {
        #expect(PickerIconName.names(kind: "image", isConcealed: true).first == "system-lock-screen-symbolic")
    }

    @Test func kindChains() {
        #expect(PickerIconName.names(kind: "link", isConcealed: false).first == "insert-link-symbolic")
        #expect(PickerIconName.names(kind: "folder", isConcealed: false).first == "folder-symbolic")
        #expect(
            PickerIconName.names(kind: "nonsense", isConcealed: false).first
                == "format-justify-left-symbolic")
    }

    /// Every chain must include a GTK built-in, so a host whose theme has no SVG
    /// loader (the build container) still draws a real glyph rather than the
    /// missing-image icon — `g_themed_icon` renders the first name present.
    @Test func everyChainIncludesABuiltIn() {
        let builtIns: Set = [
            "text-x-generic-symbolic", "view-list-symbolic", "folder-symbolic",
            "insert-image-symbolic", "changes-prevent-symbolic", "dialog-password-symbolic",
        ]
        for kind in ["text", "link", "folder", "image", "file", "nonsense"] {
            let names = Set(PickerIconName.names(kind: kind, isConcealed: false))
            #expect(!names.isDisjoint(with: builtIns))
        }
        #expect(!Set(PickerIconName.names(kind: "text", isConcealed: true)).isDisjoint(with: builtIns))
    }
}

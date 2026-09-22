import CGtk4
import Foundation
import Testing

@testable import SkrepkaLinuxUI

/// The decode itself, on the real GdkPixbuf — sized from the header the loader
/// reads and turned the way the picture's EXIF says. Needs no display: a
/// texture is memory, not a surface.
struct ThumbnailCacheTests {
    /// 3 × 2 pixels stored, with EXIF orientation 6: shown 2 × 3. Written by
    /// ImageMagick, with the `Exif` segment spliced in and read back by it as
    /// `RightTop`.
    static let rotatedJPEG =
        Data(
            base64Encoded:
                "/9j/4AAQSkZJRgABAQAAAQABAAD/4QAiRXhpZgAATU0AKgAAAAgAAQESAAMAAAABAAYAAAAAAAD/2wBDAAYEBQYFBAYGBQYHBwYI"
                + "ChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgo"
                + "KCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAACAAMDASIAAhEBAxEB/8QAFQABAQAAAAAA"
                + "AAAAAAAAAAAAAAf/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAABgj/xAAUEQEAAAAAAAAAAAAAAAAA"
                + "AAAA/9oADAMBAAIRAxEAPwCdABykX//Z") ?? Data()

    /// A flat 800 × 480 PNG, palette-encoded so it stays small.
    static let largePNG =
        Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAyAAAAHgCAMAAABq2fnHAAAAA1BMVEUzZswgIiSpAAABi0lEQVR42u3BMQEAAADCoPVPbQdvo"
                + String(repeating: "A", count: 496)
                + "OA33isAAdtyXtAAAAAASUVORK5CYII=") ?? Data()

    /// 800 × 480 stored with EXIF orientation 6, so shown 480 × 800: large
    /// enough that the decode is scaled, which is the path a real photo takes.
    static let largeRotatedJPEG =
        Data(
            base64Encoded:
                "/9j/4QAiRXhpZgAATU0AKgAAAAgAAQESAAMAAAABAAYAAAAAAAD/4AAQSkZJRgABAQAAAQABAAD/2wBDABsSFBcUERsXFhce"
                + "HBsgKEIrKCUlKFE6PTBCYFVlZF9VXVtqeJmBanGQc1tdhbWGkJ6jq62rZ4C8ybqmx5moq6T/2wBDARweHigjKE4rK06kbl1u"
                + "pKSkpKSkpKSkpKSkpKSkpKSkpKSkpKSkpKSkpKSkpKSkpKSkpKSkpKSkpKSkpKSkpKT/wAARCAHgAyADASIAAhEBAxEB/8QA"
                + "FQABAQAAAAAAAAAAAAAAAAAAAAT/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFgEBAQEAAAAAAAAAAAAAAAAAAAQF/8QAFBEB"
                + "AAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEQMRAD8AmAaKU"
                + String(repeating: "A", count: 2997)
                + "B//9k=") ?? Data()

    static func size(of texture: OpaquePointer) -> PixelSize {
        PixelSize(width: Int(gdk_texture_get_width(texture)), height: Int(gdk_texture_get_height(texture)))
    }

    @Test("a photo held on its side decodes the way it is shown")
    func appliesOrientation() throws {
        let texture = try #require(ThumbnailCache().store(hash: "rotated", data: Self.rotatedJPEG))
        #expect(Self.size(of: texture) == PixelSize(width: 2, height: 3))
    }

    @Test("a large picture is scaled down to cover the tile as it loads, knowing nothing but its bytes")
    func boundsTheDecode() throws {
        let texture = try #require(ThumbnailCache().store(hash: "large", data: Self.largePNG))
        #expect(
            Self.size(of: texture)
                == ThumbnailSizing.loaderSize(
                    source: PixelSize(width: 800, height: 480), box: ThumbnailCache.tile))
        #expect(Self.size(of: texture) == PixelSize(width: 84, height: 51))
    }

    @Test("a photo held on its side is scaled and turned, in that order")
    func scalesThenTurns() throws {
        let texture = try #require(ThumbnailCache().store(hash: "large rotated", data: Self.largeRotatedJPEG))
        let stored = ThumbnailSizing.loaderSize(
            source: PixelSize(width: 800, height: 480), box: ThumbnailCache.tile)
        #expect(Self.size(of: texture) == PixelSize(width: stored.height, height: stored.width))
    }

    @Test("bytes that are not a picture are not cached")
    func rejectsNonPictures() {
        let cache = ThumbnailCache()
        #expect(cache.store(hash: "text", data: Data("hello".utf8)) == nil)
        #expect(!cache.contains("text"))
    }
}

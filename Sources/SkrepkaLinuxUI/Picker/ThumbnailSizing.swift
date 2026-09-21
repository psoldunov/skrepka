/// A size in pixels.
struct PixelSize: Equatable {
    let width: Int
    let height: Int
}

/// The arithmetic that decides how large to decode a thumbnail.
///
/// The row draws an 84×48 tile that cover-crops its picture — `GtkPicture` with
/// `GTK_CONTENT_FIT_COVER` does the crop and any upscaling for the display.
/// What this decides is the size handed to `gdk_pixbuf_loader_set_size`, so a
/// four-megapixel screenshot is not decoded at full resolution to fill a tile
/// the size of a postage stamp. Pure, so the bound can be tested without
/// decoding anything.
enum ThumbnailSizing {
    /// The size to decode `source` to so it still covers `box`, never larger
    /// than `source` itself.
    ///
    /// A picture already smaller than the tile is decoded whole and left for
    /// `GtkPicture` to scale up — decoding cannot add detail that is not there.
    /// A larger one is scaled down to the smallest size that still covers the
    /// tile in both axes, aspect preserved, which is what `set_size` produces
    /// for a box of the source's own aspect ratio.
    static func loaderSize(source: PixelSize, box: PixelSize) -> PixelSize {
        guard source.width > 0, source.height > 0, box.width > 0, box.height > 0 else {
            return source
        }
        let scale = max(
            Double(box.width) / Double(source.width),
            Double(box.height) / Double(source.height)
        )
        guard scale < 1 else { return source }
        let width = max(box.width, Int((Double(source.width) * scale).rounded(.up)))
        let height = max(box.height, Int((Double(source.height) * scale).rounded(.up)))
        return PixelSize(width: width, height: height)
    }
}

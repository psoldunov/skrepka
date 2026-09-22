import CGtk4
import Foundation

/// Decoded thumbnails, one `GdkTexture` per content hash, kept small.
///
/// A history of thousands of entries must not pin thousands of pictures, so the
/// textures live in an ``LRUCache`` that drops the coldest when it fills. The
/// cache owns one reference to each texture it holds and drops it on eviction;
/// a `GtkPicture` showing one takes its own reference, so a texture drawn in a
/// visible row survives its eviction here until the row lets go.
///
/// Runs on GTK's loop thread and touches only GDK — like everything else in
/// this target it makes no cross-thread claim, because it never crosses one.
/// The bytes arrive from the daemon already — a picture copied as pixels, or
/// the picture file a row names — and this is where they become pixels at all:
/// the daemon links no decoder. Decoding is bounded by ``ThumbnailSizing`` so a
/// full-screen screenshot or a camera's photo is scaled down as it loads rather
/// than decoded whole.
final class ThumbnailCache {
    /// The tile a thumbnail covers, in logical pixels — the macOS 84×48
    /// preview. The source is scaled to cover this as it decodes.
    static let tile = PixelSize(width: 84, height: 48)

    private var store: LRUCache<OpaquePointer>

    init(capacity: Int = 100) {
        store = LRUCache(capacity: capacity)
    }

    /// The cached texture for `hash`, marked most-recently-used, or nil.
    func texture(for hash: String) -> OpaquePointer? {
        store.take(hash)
    }

    func contains(_ hash: String) -> Bool {
        store.contains(hash)
    }

    /// Decodes `data` into a texture, caches it under `hash`, and returns it —
    /// or nil when the bytes are not a picture GDK can read.
    @discardableResult
    func store(hash: String, data: Data) -> OpaquePointer? {
        guard let texture = decode(data) else { return nil }
        for displaced in store.insert(hash, texture) {
            g_object_unref(UnsafeMutableRawPointer(displaced))
        }
        return texture
    }

    /// The picture in `data`, scaled to cover ``tile`` and turned the way its
    /// EXIF orientation says.
    ///
    /// The scale is chosen from the size the loader reads out of the header,
    /// not the one the row's document states. That one is the size the picture
    /// is *shown* at, which for a rotated phone photo is the transpose of what
    /// is stored — and `gdk_pixbuf_loader_set_size` scales the stored pixels,
    /// so feeding it the shown size squashes them. It also bounds the decode of
    /// a picture whose document states no size at all, which a TIFF never does.
    private func decode(_ data: Data) -> OpaquePointer? {
        guard let loader = gdk_pixbuf_loader_new() else { return nil }
        defer { g_object_unref(UnsafeMutableRawPointer(loader)) }
        // Emitted during the first write that reaches the end of the header,
        // before any pixel is decoded; the loader dies with this function, and
        // the handler with it.
        skrepka_connect(
            UnsafeMutableRawPointer(loader),
            "size-prepared",
            unsafeBitCast(Self.onSizePrepared, to: GCallback.self),
            nil,
            nil
        )
        let wrote = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress, !buffer.isEmpty else { return false }
            return gdk_pixbuf_loader_write(
                loader, base.assumingMemoryBound(to: guchar.self), gsize(buffer.count), nil) != 0
        }
        let closed = gdk_pixbuf_loader_close(loader, nil) != 0
        guard wrote, closed, let pixbuf = gdk_pixbuf_loader_get_pixbuf(loader) else { return nil }
        // The loader records a JPEG's or TIFF's orientation as an option on the
        // pixbuf and leaves applying it to the caller. A new reference, or a
        // second one to `pixbuf` when there is nothing to turn.
        guard let oriented = gdk_pixbuf_apply_embedded_orientation(pixbuf) else { return nil }
        defer { g_object_unref(UnsafeMutableRawPointer(oriented)) }
        return gdk_texture_new_for_pixbuf(oriented)
    }

    private typealias SizePrepared =
        @convention(c) (UnsafeMutablePointer<GdkPixbufLoader>?, Int32, Int32, gpointer?) -> Void

    /// `size-prepared`: asks for the smallest size that still covers the tile.
    private static let onSizePrepared: SizePrepared = { loader, width, height, _ in
        let size = ThumbnailSizing.loaderSize(
            source: PixelSize(width: Int(width), height: Int(height)), box: tile)
        gdk_pixbuf_loader_set_size(loader, Int32(size.width), Int32(size.height))
    }
}

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
/// The bytes arrive from the daemon already; decoding is bounded by
/// ``ThumbnailSizing`` so a full-screen screenshot is scaled down as it loads
/// rather than decoded whole.
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
    ///
    /// - Parameter source: the picture's own size, from the row's
    ///   ``ClipDocument``, so the decode can be scaled to cover the tile without
    ///   knowing the bytes first. Nil decodes at full size.
    @discardableResult
    func store(hash: String, data: Data, source: PixelSize?) -> OpaquePointer? {
        guard let texture = decode(data, source: source) else { return nil }
        for displaced in store.insert(hash, texture) {
            g_object_unref(UnsafeMutableRawPointer(displaced))
        }
        return texture
    }

    private func decode(_ data: Data, source: PixelSize?) -> OpaquePointer? {
        guard let loader = gdk_pixbuf_loader_new() else { return nil }
        defer { g_object_unref(UnsafeMutableRawPointer(loader)) }
        if let source {
            let size = ThumbnailSizing.loaderSize(source: source, box: Self.tile)
            gdk_pixbuf_loader_set_size(loader, Int32(size.width), Int32(size.height))
        }
        let wrote = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress, !buffer.isEmpty else { return false }
            return gdk_pixbuf_loader_write(
                loader, base.assumingMemoryBound(to: guchar.self), gsize(buffer.count), nil) != 0
        }
        let closed = gdk_pixbuf_loader_close(loader, nil) != 0
        guard wrote, closed, let pixbuf = gdk_pixbuf_loader_get_pixbuf(loader) else { return nil }
        return gdk_texture_new_for_pixbuf(pixbuf)
    }
}

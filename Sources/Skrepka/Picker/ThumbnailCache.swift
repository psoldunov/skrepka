import AppKit
import Foundation
import SkrepkaCore

/// Decoded row thumbnails, keyed by entry id.
///
/// `NSImage(data:)` inside a view's computed property re-decodes on every body
/// evaluation, and rows re-evaluate on every keystroke and every arrow press.
/// A history entry's thumbnail never changes, so its id is a safe key.
///
/// `NSCache` rather than a dictionary: it evicts under memory pressure on its
/// own, which matters when the store holds hundreds of image entries and each
/// decoded thumbnail is a quarter of a megabyte.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    /// Well above a full panel of visible rows, well below the retention cap.
    private static let capacity = 128

    private let images = NSCache<NSUUID, NSImage>()

    private init() {
        images.countLimit = Self.capacity
    }

    /// The decoded thumbnail, or nil when the entry has none or it will not
    /// decode — either way the row falls back to a kind symbol.
    func image(for item: ClipSummary) -> NSImage? {
        let key = item.id as NSUUID
        if let cached = images.object(forKey: key) { return cached }
        guard let data = item.thumbnail, let image = NSImage(data: data) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }
}

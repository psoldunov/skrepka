import AppKit
import Foundation
import SkrepkaCore

/// Decoded row thumbnails, keyed by entry id.
///
/// Two costs, one cache. `ClipSummary` carries no picture — the store holds one
/// summary per entry the retention cap allows and the picker draws about twenty,
/// so publishing every thumbnail read and then kept resident every picture in
/// the history — and `NSImage(data:)` inside a view's computed property
/// re-decodes on every body evaluation, which rows do on every keystroke and
/// every arrow press. So a miss reads the bytes from the store and decodes them
/// once, and a hit does neither. A history entry's thumbnail never changes after
/// it exists, so its id is a safe key.
///
/// `NSCache` rather than a dictionary: it evicts under memory pressure on its
/// own, which matters when each decoded thumbnail is a quarter of a megabyte.
@MainActor
final class ThumbnailCache {
    /// Well above a full panel of visible rows, well below the retention cap.
    private static let capacity = 128

    private let store: HistoryStore
    private let images = NSCache<NSUUID, NSImage>()

    init(store: HistoryStore) {
        self.store = store
        images.countLimit = Self.capacity
    }

    /// The decoded thumbnail, or nil when the entry has none, is concealed, or
    /// its stored bytes will not decode — in every case the row falls back to a
    /// kind symbol.
    ///
    /// The ``ClipSummary/hasThumbnail`` guard is what keeps a history of text
    /// entries off the store entirely: without it every text row would ask for
    /// bytes that are not there, on every body evaluation, because a miss is not
    /// cached. Caching misses instead would be wrong — a repeat copy backfills a
    /// preview onto an entry that had none.
    func image(for item: ClipSummary) -> NSImage? {
        guard item.hasThumbnail, !item.isConcealed else { return nil }

        let key = item.id as NSUUID
        if let cached = images.object(forKey: key) { return cached }
        guard let data = store.thumbnail(for: item.id), let image = NSImage(data: data) else {
            return nil
        }
        images.setObject(image, forKey: key)
        return image
    }
}

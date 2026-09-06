import AppKit
import Foundation
import SkrepkaCore

/// Decoded row thumbnails and file-icon stacks, keyed by entry id.
///
/// Two costs, one cache. `ClipSummary` carries no picture — the store holds one
/// summary per entry the retention cap allows and the picker draws about twenty,
/// so publishing every thumbnail read and then kept resident every picture in
/// the history — and `NSImage(data:)` inside a view's computed property
/// re-decodes on every body evaluation, which rows do on every keystroke and
/// every arrow press. So a miss reads the bytes from the store and decodes them
/// once, and a hit does neither.
///
/// An entry's *preview* never changes — `HistoryStore.backfillPreview` writes
/// one only where there was none — so its id alone is a safe key. Its *stack*
/// does change: a repeat copy rewrites the file list and the stack drawn from
/// it, and the row's id does not change with them. So that half of the cache
/// keys on the entry's ``ClipSummary/createdAt`` as well, which a repeat copy is
/// exactly what bumps.
///
/// `NSCache` rather than a dictionary: it evicts under memory pressure on its
/// own, which matters when each decoded thumbnail is a quarter of a megabyte.
@MainActor
final class ThumbnailCache {
    /// Well above a full panel of visible rows, well below the retention cap.
    private static let capacity = 128

    private let store: HistoryStore
    private let images = NSCache<NSUUID, NSImage>()
    /// Stacks are cached whole: a row draws all of its layers or none of them,
    /// and `NSCache` cannot hold a Swift array, so the box is what goes in.
    private let stacks = NSCache<NSUUID, StackBox>()

    init(store: HistoryStore) {
        self.store = store
        images.countLimit = Self.capacity
        stacks.countLimit = Self.capacity
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

    /// The decoded icons of the files this entry holds, front first, or empty
    /// when it holds too few to stack.
    ///
    /// Cached for the same reason as the preview, and more so: a stack is three
    /// decodes per row rather than one, and the rows re-evaluate on every
    /// keystroke.
    ///
    /// Kept only while it still pictures what the row holds. A repeat copy of a
    /// selection rewrites both the file list and the stack drawn from it — see
    /// `HistoryStore.backfillStack`, which replaces rather than keeps for
    /// exactly that reason — and the row's id does not change with it, so an
    /// id-only lookup went on drawing the icons of the files the row used to
    /// lead with. The stamp it is checked against is ``ClipSummary/createdAt``,
    /// because a repeat copy is the only thing that rewrites a stack and it
    /// always bumps that. A merge from a peer bumps it without touching the
    /// stack — icons of local files never cross the wire — which costs one
    /// wasted decode and draws the right picture either way.
    ///
    /// All the layers or none, matching how the stack was built: a stack short
    /// one layer promotes the second file to the front, and the front layer is
    /// the file the row leads with — see
    /// ``FileIconStack/icons(forFilesAt:maximum:)``.
    ///
    /// The ``ClipSummary/hasStackIcons`` guard keeps every other row off the
    /// store, for the reason ``image(for:)`` gives about text rows.
    func stackImages(for item: ClipSummary) -> [NSImage] {
        guard item.hasStackIcons, !item.isConcealed else { return [] }

        let key = item.id as NSUUID
        if let cached = stacks.object(forKey: key), cached.capturedAt == item.createdAt {
            return cached.images
        }
        let icons = store.stackIcons(for: item.id)
        let decoded = icons.compactMap(NSImage.init(data:))
        let images = decoded.count == icons.count ? decoded : []
        stacks.setObject(StackBox(capturedAt: item.createdAt, images: images), forKey: key)
        return images
    }
}

/// `NSCache` is an Objective-C class and holds objects, not Swift arrays.
///
/// Carries the ``ClipSummary/createdAt`` it was decoded for as well as the
/// images, so a lookup can tell a stack that still fits its row from one left
/// over from an earlier copy.
private final class StackBox {
    let capturedAt: Date
    let images: [NSImage]

    init(capturedAt: Date, images: [NSImage]) {
        self.capturedAt = capturedAt
        self.images = images
    }
}

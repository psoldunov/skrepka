import AppKit
import Foundation
import SkrepkaCore

/// Decoded row thumbnails, keyed by entry id.
///
/// `NSImage(data:)` inside a view's computed property re-decodes on every body
/// evaluation, and rows re-evaluate on every keystroke and every arrow press.
///
/// An entry's *preview* never changes — `HistoryStore.backfillPreview` writes
/// one only where there was none — so its id alone is a safe key. Its *stack*
/// does change: the same row is redrawn whenever a repeat copy rewrites the
/// file list it pictures, so that half of the cache checks what it holds
/// against what it was asked for rather than trusting the id.
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
    /// Stacks are cached whole: a row draws all of its layers or none of them,
    /// and `NSCache` cannot hold a Swift array, so the box is what goes in.
    private let stacks = NSCache<NSUUID, StackBox>()

    private init() {
        images.countLimit = Self.capacity
        stacks.countLimit = Self.capacity
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
    /// lead with. Comparing the bytes costs a `memcmp` of the three icons
    /// against three decodes, which is the cheaper side by orders of magnitude —
    /// and it rarely reads a byte at all: `Array`'s own `==` returns early on
    /// differing counts and on two arrays sharing one allocation, and the box
    /// holds the summary's own array rather than a copy of it, so a row drawn
    /// twice with no capture in between settles by pointer.
    ///
    /// All the layers or none, matching how the stack was built: a stack short
    /// one layer promotes the second file to the front, and the front layer is
    /// the file the row leads with — see
    /// ``FileIconStack/icons(forFilesAt:maximum:)``.
    func stackImages(for item: ClipSummary) -> [NSImage] {
        guard !item.stackIcons.isEmpty else { return [] }
        let key = item.id as NSUUID
        if let cached = stacks.object(forKey: key), cached.icons == item.stackIcons {
            return cached.images
        }
        let decoded = item.stackIcons.compactMap(NSImage.init(data:))
        let images = decoded.count == item.stackIcons.count ? decoded : []
        stacks.setObject(StackBox(icons: item.stackIcons, images: images), forKey: key)
        return images
    }
}

/// `NSCache` is an Objective-C class and holds objects, not Swift arrays.
///
/// Carries the icons it was decoded from as well as the images, so a lookup can
/// tell a stack that still fits its row from one left over from an earlier copy.
/// The `Data` values are the ones already held by the summary, so keeping them
/// here shares those buffers rather than copying them.
private final class StackBox {
    let icons: [Data]
    let images: [NSImage]

    init(icons: [Data], images: [NSImage]) {
        self.icons = icons
        self.images = images
    }
}

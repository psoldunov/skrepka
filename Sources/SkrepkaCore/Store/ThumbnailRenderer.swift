// AppKit-only by way of ThumbnailMaker. Excluded rather than hidden behind a
// ThumbnailProducing protocol: per D-9 that protocol would give macOS one real
// conformance and one nil-returning stub — a cost with no macOS benefit. Phase 7
// introduces it, when GdkPixbuf makes the second conformance real.
#if canImport(AppKit)

    import Foundation

    /// Generates row previews off the main actor.
    ///
    /// ``HistoryStore`` is main-actor because it owns the SwiftData main context,
    /// and capture runs on every clipboard change. Previewing a copied *file* means
    /// opening it, and that read is only as fast as the volume it sits on: a stale
    /// SMB mount blocks until the mount times out, and a large original on an
    /// external disk costs real milliseconds. Neither belongs on the actor drawing
    /// the menu bar and the picker.
    ///
    /// An actor rather than a detached task per capture, so previews are generated
    /// one at a time in the order they were asked for. Two copies in quick
    /// succession do not race to decode at once.
    public actor ThumbnailRenderer {
        private let maker: ThumbnailMaker

        public init(maker: ThumbnailMaker = ThumbnailMaker()) {
            self.maker = maker
        }

        /// A preview for the item, or nil when its kind has no picture to show or
        /// the payload turns out not to hold one.
        func preview(for item: ClipItem) -> ThumbnailMaker.Preview? {
            guard item.kind.canPreview else { return nil }
            return maker.makePreview(from: item.payload)
        }
    }

#endif

import Foundation

/// Reads what a row needs off the copied content, off the main actor.
///
/// ``HistoryStore`` is main-actor because it owns the SwiftData main context,
/// and capture runs on every clipboard change. Previewing a copied *file* means
/// opening it, and measuring a copied *folder* means walking it; both are only
/// as fast as the volume they sit on, and a stale SMB mount blocks until the
/// mount times out. Neither belongs on the actor drawing the menu bar and the
/// picker.
///
/// An actor rather than a detached task per capture, so details are produced
/// one at a time in the order they were asked for. Two copies in quick
/// succession do not race to decode at once.
public actor ThumbnailRenderer {
    private let maker: ThumbnailMaker

    public init(maker: ThumbnailMaker = ThumbnailMaker()) {
        self.maker = maker
    }

    /// The preview and the size for an item. Either half is nil when the entry
    /// has none to give — see ``ClipKind/canPreview`` and ``ContentSize``.
    func details(for item: ClipItem) -> ClipDetails {
        ClipDetails(
            preview: item.kind.canPreview ? maker.makePreview(from: item.payload) : nil,
            byteCount: ContentSize.byteCount(of: item)
        )
    }
}

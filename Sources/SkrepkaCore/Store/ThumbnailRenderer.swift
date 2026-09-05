// AppKit-only by way of ThumbnailMaker. Excluded rather than hidden behind a
// ThumbnailProducing protocol: per D-9 that protocol would give macOS one real
// conformance and one nil-returning stub — a cost with no macOS benefit. Phase 7
// introduces it, when GdkPixbuf makes the second conformance real.
#if canImport(AppKit)

    import Foundation

    /// Reads what a row needs off the copied content, off the main actor.
    ///
    /// ``HistoryStore`` is main-actor because it owns the SwiftData main context,
    /// and capture runs on every clipboard change. Telling a copied *folder* from
    /// a copied file means asking the file system about it, previewing a copied
    /// *file* means opening it, and measuring a folder means walking it; all three
    /// are only as fast as the volume they sit on, and a stale SMB mount blocks
    /// until the mount times out. None of it belongs on the actor drawing the menu
    /// bar and the picker — nor in ``ClipboardWatcher``'s poll, where a stall
    /// would lose the copies made during it rather than merely delay a row.
    ///
    /// An actor rather than a detached task per capture, so details are produced
    /// one at a time in the order they were asked for. Two copies in quick
    /// succession do not race to decode at once.
    public actor ThumbnailRenderer {
        private let maker: ThumbnailMaker

        public init(maker: ThumbnailMaker = ThumbnailMaker()) {
            self.maker = maker
        }

        /// Everything about an entry that needed the copied thing opened. Any part
        /// is nil when the entry has none to give — see ``FileURLKind``,
        /// ``ClipKind/canPreview`` and ``ContentSize``.
        func details(for item: ClipItem) -> ClipDetails {
            let kind = refinedKind(for: item)
            return ClipDetails(
                kind: kind,
                // The refined kind, so a directory that turned out to be a plain
                // folder is never opened looking for a picture it cannot hold.
                preview: (kind ?? item.kind).canPreview ? maker.makePreview(from: item.payload) : nil,
                byteCount: ContentSize.byteCount(of: item)
            )
        }

        /// What the entry's file URL actually points at, for the one kind the
        /// capture rules cannot settle on their own.
        private func refinedKind(for item: ClipItem) -> ClipKind? {
            guard item.kind.isFileSystemEntry, let url = item.payload.fileURL else { return nil }
            return FileURLKind.kind(ofFileAt: url)
        }
    }

#endif

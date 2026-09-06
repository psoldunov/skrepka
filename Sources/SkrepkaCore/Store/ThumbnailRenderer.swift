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
        ///
        /// The file system is asked once per file, here, and the answer is read
        /// by both the kind and the size. They want overlapping things from the
        /// same lookup, and on a mount that has stopped responding a second one
        /// is a second full stall — see ``CopiedSelection``.
        func details(for item: ClipItem) -> ClipDetails {
            let selection = copiedSelection(for: item)
            let kind = FileURLKind.kind(of: selection)
            // The refined kind, so a directory that turned out to be a plain
            // folder is never opened looking for a picture it cannot hold.
            let preview = (kind ?? item.kind).canPreview ? maker.makePreview(from: item.payload) : nil
            return ClipDetails(
                kind: Self.kind(kind, provenPictureBy: preview, fileCount: item.fileURLs.count),
                preview: preview,
                stackIcons: stackIcons(for: item),
                byteCount: ContentSize.byteCount(of: item, selection: selection)
            )
        }

        /// What the file system says about every file the entry names, for the
        /// kinds that name one.
        ///
        /// ``CopiedSelection/empty`` for an entry that names no file, which both
        /// readers already turn into "nothing to say".
        private func copiedSelection(for item: ClipItem) -> CopiedSelection {
            guard item.kind.isFileSystemEntry else { return .empty }
            return CopiedSelection.look(at: item.fileURLs)
        }

        /// The pictures a row holding several files draws as a stack, or nil when
        /// the entry holds one file or none.
        ///
        /// Nil rather than an empty array, for the reason every part of
        /// ``ClipDetails`` is optional: a row already carrying a stack must not
        /// lose it to a later copy that could produce none.
        private func stackIcons(for item: ClipItem) -> [Data]? {
            guard item.fileURLs.count > 1 else { return nil }
            let icons = FileIconStack.icons(forFilesAt: item.fileURLs)
            return icons.isEmpty ? nil : icons
        }

        /// Upgrades a plain file to ``ClipKind/imageFile`` once a picture has
        /// actually been drawn out of it.
        ///
        /// ``FileURLKind`` answers from the file's declared type, which a file
        /// with no extension does not have — it reports the generic
        /// `public.data`, and a screenshot saved without one would read "File"
        /// under its own preview. A rendered thumbnail is the stronger evidence,
        /// and by here it exists.
        ///
        /// Only a lone file is upgraded: the preview of a selection is a picture
        /// of its first file, which says nothing about the ones behind it, and a
        /// row reading "4 Images" for one screenshot and three spreadsheets is a
        /// worse lie than the "4 Files" it would replace.
        static func kind(
            _ kind: ClipKind?,
            provenPictureBy preview: ThumbnailMaker.Preview?,
            fileCount: Int
        ) -> ClipKind? {
            guard kind == .file, fileCount == 1, preview != nil else { return kind }
            return .imageFile
        }
    }

#endif

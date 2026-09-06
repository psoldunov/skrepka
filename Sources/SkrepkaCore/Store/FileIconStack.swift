// AppKit-only: NSWorkspace icons and the PNG re-encode beside them, like the
// ThumbnailMaker it draws through. Linux draws no stacks yet — see D-9 and
// Phase 7, where GdkPixbuf and an icon theme make the second conformance real.
#if canImport(AppKit)

    import AppKit
    import Foundation

    /// The pictures a row draws when one entry holds several files: the front one
    /// and the couple peeking out behind it, the way the Dock draws a stack.
    ///
    /// A selection previewed by its first file alone reads as one file. What tells a
    /// copy of three apart at a glance is seeing three things, and what makes those
    /// three recognisable is that each is the file's own icon — the app's artwork,
    /// the folder, the PDF badge — rather than a repeated grey glyph.
    ///
    /// A picture is drawn from its own bytes, because a photograph is more use than
    /// the generic image-file icon. Everything else falls back to what the Finder
    /// would show, which is exactly what `NSWorkspace` hands over.
    ///
    /// Rendered here rather than in the view: the icons come off disk, and both
    /// callers reach this through ``ThumbnailRenderer``, off the main actor, with
    /// everything else that has to open the copied files.
    enum FileIconStack {
        /// Longest edge of a stacked icon, in pixels. Smaller than
        /// ``ThumbnailMaker/maximumEdge`` because a stack layer is drawn at about
        /// half the width of a single row preview, and three of them are stored per
        /// entry rather than one.
        static let maximumEdge = 128

        /// A picture for each of the first `maximum` files, front first — or none at
        /// all, if any one of them could not be drawn.
        ///
        /// Empty when `urls` is empty. Rarely empty otherwise: a file that will not
        /// decode still yields its system icon, and `NSWorkspace` answers for a path
        /// deleted since the copy too — with the generic document icon, which is the
        /// honest picture of "a file we can no longer look inside". What is left is
        /// an allocation or encoding failure inside ``ThumbnailMaker/png(from:targetSize:)``,
        /// which says nothing about the file and can strike one call and not the next.
        ///
        /// All or nothing when it does, and for the reason ``ContentSize`` gives for
        /// a selection's size: a partial answer is a wrong one that looks right.
        /// Depth carries meaning here — the front layer is the file the entry leads
        /// with, the file its payload pastes — so dropping a failed icon from the
        /// middle promotes the next file to the front and the row pictures the wrong
        /// file as its leader. Returning none instead leaves the row with the
        /// preview and count badge it had before stacks existed, which is a smaller
        /// and honest thing to show.
        ///
        /// The guard is deliberately not covered by a test: the only failure it
        /// catches is a bitmap allocation that no test can provoke without injecting
        /// a renderer, which is machinery this does not otherwise need.
        static func icons(
            forFilesAt urls: [URL],
            maximum: Int = FileSelection.maximumStackedIcons
        ) -> [Data] {
            var drawn: [Data] = []
            drawn.reserveCapacity(min(maximum, urls.count))

            for url in urls.prefix(maximum) {
                guard let icon = icon(forFileAt: url) else { return [] }
                drawn.append(icon)
            }
            return drawn
        }

        /// The file's own picture when it is one, its system icon otherwise.
        static func icon(forFileAt url: URL) -> Data? {
            if let preview = ImageFileThumbnail.preview(ofFileAt: url, maximumEdge: maximumEdge) {
                return preview.thumbnail
            }
            return systemIcon(forFileAt: url)
        }

        /// What the Finder draws for this file, scaled to a row.
        ///
        /// `icon(forFile:)` is not annotated for the main actor in the macOS 26 SDK
        /// — verified against `NSWorkspace.h` and by compiling a call to it from
        /// inside an actor — so reading it here, off the main actor, is sanctioned
        /// rather than merely tolerated.
        /// Drawn at the full stack size rather than scaled down to fit: an icon
        /// measures 32 points and carries representations up to 512 pixels, so
        /// asking for 128 gets a crisp 128 rather than a blown-up 32.
        private static func systemIcon(forFileAt url: URL) -> Data? {
            let icon = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
            let side = CGFloat(maximumEdge)
            return ThumbnailMaker.png(from: icon, targetSize: CGSize(width: side, height: side))
        }
    }

#endif

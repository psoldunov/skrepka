import Foundation
import SkrepkaCore
import SkrepkaSync
import os

/// What goes on the pasteboard for a file row another device recorded — a
/// live push, or a synced row picked from the history — as one dictionary per
/// pasteboard item.
///
/// The rule is ``ForeignFileGuard``'s: never the other machine's path. Files
/// that came with the row are written to the cache and pasted as local files,
/// the way Finder puts them up; anything else pastes as the files' names.
///
/// Off the main actor: materialising a bundle writes up to 32 MB, and a JPEG
/// is decoded and re-encoded as PNG so apps that read no JPEG paste it too.
nonisolated enum ForeignFilePasteboard {
    /// The row as the decision needs it.
    struct Row: Sendable {
        let kind: ClipKind
        let representations: [String: Data]
        /// The row's text, which names its files.
        let preview: String
        let contentHash: String
        let isForeign: Bool
    }

    /// The pasteboard items for `row`, or nil when it is not a foreign file
    /// row and its payload should be written as held.
    ///
    /// - Parameter cache: where received files are written. Nil when the
    ///   caches folder could not be found, and then the row pastes its names.
    @concurrent
    static func items(for row: Row, cache: FileCache?) async -> [[String: Data]]? {
        switch ForeignFileGuard.decide(
            kind: row.kind,
            representations: row.representations,
            preview: row.preview,
            isForeign: row.isForeign
        ) {
        case .passThrough:
            return nil
        case .names(let text):
            return PasteboardFileItems.items(for: ForeignFileGuard.clipboard(forNames: text))
        case .files(let bundle):
            return filesItems(bundle, of: row, cache: cache)
        }
    }

    private static func filesItems(_ bundle: FileBundle, of row: Row, cache: FileCache?) -> [[String: Data]] {
        guard let cache else { return namesItems(row) }
        do {
            let urls = try FileMaterializer.materialize(bundle, contentHash: row.contentHash, in: cache)
            let clipboard = ForeignFileGuard.clipboard(forFilesAt: urls, from: bundle)
            let png = PasteboardFileItems.pictureNeedingPNG(in: clipboard.payload)
                .flatMap { PasteboardFileItems.pngTranscode(of: $0) }
            return PasteboardFileItems.items(for: clipboard, png: png)
        } catch {
            // Names rather than nothing: the user asked for this row, and the
            // names are the same fallback a row without files gets.
            SkrepkaLog.sync.error(
                "Could not write received files, pasting their names: \(String(describing: error), privacy: .public)"
            )
            return namesItems(row)
        }
    }

    private static func namesItems(_ row: Row) -> [[String: Data]] {
        PasteboardFileItems.items(for: ForeignFileGuard.clipboard(forNames: row.preview))
    }
}

// MARK: - Where received files live

extension FileCache {
    /// `~/Library/Caches/<bundle id>` — the cache adds its own `files/` —
    /// or nil when the system names no caches folder.
    ///
    /// Caches rather than Application Support: every file here is a copy of
    /// bytes the history database also holds, so the system purging it costs
    /// one rewrite at the next paste.
    nonisolated static func application() -> FileCache? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.soldunov.skrepka"
        return FileCache(root: caches.appending(path: bundleID, directoryHint: .isDirectory))
    }
}

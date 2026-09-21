import Foundation
import SkrepkaSync

#if canImport(os)
    import os
#else
    import Logging
#endif

/// Reads the files a copy names into a ``SkrepkaSync/FileBundle``, so the copy
/// can reach a peer as files rather than as a path that exists only here.
///
/// Read at copy time, after the capture rules have judged the copy — those stay
/// a pure function of what the clipboard held, and reading a disk is neither.
/// A file moved or deleted after the copy still reaches the peer as it was.
///
/// Portable: the same reader runs behind the Mac's capture path and the Linux
/// daemon's.
public enum FileBundleReader {
    /// Most bytes one bundle may hold, encoding included: the protocol's
    /// payload ceiling, since a bundle is one representation.
    public static let limit = SyncLimits.maximumPayloadBytes

    /// What reading a copy came to.
    public enum Outcome: Sendable, Hashable {
        /// At least one file was read, and everything read fits.
        case bundle(FileBundle)
        /// The files together exceed the limit; nothing is bundled.
        case tooLarge
        /// Nothing the copy names is a readable regular file — folders only,
        /// or files gone or unreadable since the copy.
        case nothingToBundle
    }

    /// The copy with its files' contents attached as a bundle representation,
    /// or the copy unchanged when there is nothing to attach.
    ///
    /// Call it once per copy, after the capture rules accepted it and before
    /// the copy is stored or pushed, and hand the result to both: the store
    /// keeps the bundle and serves it to peers, and a live push carries it.
    /// `contentHash` is recomputed, and now covers the files' contents as well
    /// as their paths — see `ClipItem.hash(kind:text:payload:fileURLs:)` — so
    /// a file edited in place and copied again is a new row, not the old one
    /// with stale bytes.
    ///
    /// Concealed copies are left alone: they never cross the wire, so there is
    /// nothing to read them for.
    ///
    /// `limit` is the user's file-size limit — `SkrepkaSync.FileSyncLimit` —
    /// clamped to the protocol ceiling. At 0 nothing is read at all: "don't
    /// sync file contents" also means "don't keep them".
    @concurrent
    public static func attachingBundle(to item: ClipItem, limit: Int = limit) async -> ClipItem {
        let limit = FileSyncLimit.clamped(limit)
        guard limit > 0, item.kind.isFileSystemEntry, !item.isConcealed, !item.fileURLs.isEmpty,
            item.payload.data(forType: FileBundle.storageType) == nil,
            case .bundle(let bundle) = read(item.fileURLs, limit: limit),
            let encoded = encodedWithinLimit(bundle, limit: limit)
        else { return item }
        var representations = item.payload.representations
        representations[FileBundle.storageType] = encoded
        return ClipItem(
            id: item.id,
            kind: item.kind,
            text: item.text,
            payload: ClipPayload(representations: representations),
            sourceBundleID: item.sourceBundleID,
            createdAt: item.createdAt,
            isPinned: item.isPinned,
            isConcealed: item.isConcealed,
            imageSize: item.imageSize,
            fileURLs: item.fileURLs
        )
    }

    /// Reads every regular file `urls` names, in order, skipping folders and
    /// anything unreadable. Synchronous and blocking; the capture path reaches
    /// it through ``attachingBundle(to:limit:)``, which runs off the caller's
    /// actor.
    ///
    /// Each file is opened once and judged by its descriptor — see
    /// ``OpenedFile`` — so a copy of a 4 GB video costs an `fstat`, not 4 GB of
    /// memory, and nothing swapped in behind the path can block or overshoot.
    public static func read(_ urls: [URL], limit: Int = limit) -> Outcome {
        var files: [FileBundle.File] = []
        var total = 0
        for url in urls where url.isFileURL {
            switch OpenedFile.read(url.resolvingSymlinksInPath(), atMost: limit - total) {
            case .bytes(let bytes):
                guard files.count < FileBundle.maximumFileCount else { return .tooLarge }
                total += bytes.count
                // Named as the user copied it, not as a symlink's target is.
                files.append(FileBundle.File(name: url.lastPathComponent, bytes: bytes))
            case .tooLarge:
                return .tooLarge
            case .notARegularFile:
                // A folder, a device, something gone or unreadable: skipped,
                // and the rest of the copy still travels.
                continue
            }
        }
        return files.isEmpty ? .nothingToBundle : .bundle(FileBundle(files: files))
    }

    /// The encoded bundle, or nil when encoding or its framing pushed it over
    /// the limit — a copy of many tiny files right at the edge.
    private static func encodedWithinLimit(_ bundle: FileBundle, limit: Int) -> Data? {
        do {
            let encoded = try bundle.encoded()
            return encoded.count <= limit ? encoded : nil
        } catch {
            SkrepkaLog.store.error("Could not encode copied files for sync: \(String(describing: error))")
            return nil
        }
    }
}

import Foundation
import SkrepkaSync

#if canImport(os)
    import os
#else
    import Logging
#endif

/// Where files received from peers are written, one directory per item:
/// `<root>/files/<contentHash>/<name>`.
///
/// The root is the caller's — each platform has its own cache location — and
/// everything under `files/` belongs to this type. A directory is named by the
/// content hash of the history row it serves, which is what lets a row's files
/// be found again at paste time and removed with the row.
public struct FileCache: Sendable, Hashable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The directory every item's files live under.
    public var filesDirectory: URL {
        root.appendingPathComponent("files", isDirectory: true)
    }

    /// The directory one item's files are written to, or nil for a hash that
    /// is not one.
    ///
    /// A content hash arrives from a peer, and a peer is authenticated rather
    /// than trusted: `../../Library` is a string it can send. Only 64 lowercase
    /// hex characters — what `ClipItem.contentHash` produces — name a
    /// directory, so none can name one outside ``filesDirectory``.
    public func directory(for contentHash: String) -> URL? {
        guard ContentHash.isValid(contentHash) else { return nil }
        return filesDirectory.appendingPathComponent(contentHash, isDirectory: true)
    }

    /// The names under ``filesDirectory`` — content hashes, unless something
    /// else put a file there. Empty when nothing was ever materialised, which
    /// is what lets a store skip a sweep without asking its database anything.
    public func entries() -> [String] {
        // No directory yet is nothing cached, not a fault.
        (try? FileManager.default.contentsOfDirectory(atPath: filesDirectory.path)) ?? []
    }

    /// Removes the files of every item not in `live`, and anything else under
    /// ``filesDirectory`` that is not an item's directory. Answers how many
    /// entries went.
    ///
    /// Called when rows are deleted or evicted, and once at launch for the
    /// ones a crash or a deletion path that does not sweep left behind.
    /// Best-effort by design: a directory that cannot be removed now is
    /// removed on the next sweep, and nothing reads it in the meantime.
    @discardableResult
    public func sweep(keeping live: Set<String>) -> Int {
        let manager = FileManager.default
        var removed = 0
        for entry in entries() where !live.contains(entry) {
            do {
                try manager.removeItem(at: filesDirectory.appendingPathComponent(entry))
                removed += 1
            } catch {
                SkrepkaLog.store.error("Could not remove cached files \(entry): \(String(describing: error))")
            }
        }
        return removed
    }
}

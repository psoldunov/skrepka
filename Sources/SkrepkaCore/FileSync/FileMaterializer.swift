import Foundation
import SkrepkaSync

/// Turns a file bundle a peer sent into files on this machine, so a clipboard
/// here can be handed paths that exist here.
///
/// Writes to `<cache>/files/<contentHash>/<name>` — see ``FileCache`` — with
/// every name passed through ``SafeFileName`` first. Idempotent: pasting the
/// same row twice finds its files already there and writes nothing.
public enum FileMaterializer {
    public enum Failure: Error, Equatable {
        /// The hash cannot name a directory. See ``FileCache/directory(for:)``.
        case notAContentHash(String)
        /// A directory on the way to the files is a symlink, not a directory,
        /// or not this user's. See ``OwnedDirectory``.
        case untrustedDirectory(String)
    }

    /// Writes the bundle's files, if they are not written already, and answers
    /// their local URLs in bundle order.
    ///
    /// Blocking file I/O — up to ``FileBundleReader/limit`` bytes on a first
    /// call — so call it off the main actor.
    public static func materialize(
        _ bundle: FileBundle,
        contentHash: String,
        in cache: FileCache
    ) throws -> [URL] {
        guard let directory = cache.directory(for: contentHash) else {
            throw Failure.notAContentHash(contentHash)
        }
        for step in [cache.root, cache.filesDirectory, directory] {
            try OwnedDirectory.prepare(step)
        }
        let names = SafeFileName.names(for: bundle.files.map(\.name))
        return try zip(bundle.files, names).map { file, name in
            let url = directory.appendingPathComponent(name, isDirectory: false)
            // `.atomic` writes a temporary file and renames it over `url`, and
            // a rename replaces a symlink standing at `url` rather than
            // writing through it.
            if !isWritten(file, at: url) {
                try file.bytes.write(to: url, options: .atomic)
            }
            return url
        }
    }

    /// Whether `url` already holds this file — measured by size, which is
    /// enough: the directory is named by the content hash, and only this type
    /// writes into it, atomically.
    private static func isWritten(_ file: FileBundle.File, at url: URL) -> Bool {
        // Unreadable attributes mean "not written", and the write that follows
        // either succeeds or says why.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = (attributes[.size] as? NSNumber)?.intValue
        else { return false }
        return size == file.bytes.count
    }
}

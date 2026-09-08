import Foundation
import Logging

#if canImport(Glibc)
    import Glibc
#endif

/// Getting the device key onto the disk, and knowing that it is there.
///
/// Split out of `FileTrustStore.swift` because the durability rules are the
/// long half of that type and the file had reached its line limit; the ordering
/// here — exclusive create, `fsync`, checked `close`, directory `fsync` — is
/// the whole of what stops this machine from silently un-pairing itself, so it
/// is worth reading in one piece.
extension FileTrustStore {
    /// Creates the file with ``identityMode`` and writes it, refusing to
    /// overwrite one that already exists.
    ///
    /// `O_EXCL` is the race this cares about: two daemons started against one
    /// directory must not each generate an identity and have the second
    /// silently replace the first, because the first may already have been
    /// pinned by a peer. It also makes the "file appeared between the read
    /// above and this write" case fail loudly instead of destroying an identity.
    ///
    /// ## Why not a temporary file and a rename
    ///
    /// The usual atomic-write recipe would lose exactly the guarantee above:
    /// `rename(2)` replaces whatever is at the destination, so two daemons
    /// racing would each write their own identity and the loser's would win.
    /// So the create stays exclusive, and durability is bought the other way —
    /// write everything, `fsync`, then check the `close`.
    ///
    /// ## Why a failure unlinks, and only before `fsync` returns
    ///
    /// A truncated `device.key` is unreadable, and ``IdentityError/unreadable``
    /// is deliberately never repaired by generating a new one — so a
    /// half-written file would wedge `skrepkad` on every boot until a human
    /// moved it aside. Removing the partial file is what makes the next start
    /// a retry rather than the same failure for ever.
    ///
    /// **The boundary is `fsync`.** Once it has returned 0 the bytes are on
    /// the disk and the file is a whole identity whatever happens afterwards,
    /// so nothing past that point unlinks: removing it there would destroy a
    /// key a peer may already have pinned, and the next start would generate a
    /// fresh certificate and a fresh `SyncDeviceID` — silently un-pairing this
    /// machine from every peer it has. That is why the `close` sits outside the
    /// `do`, and why a `close` that fails is logged rather than thrown: the
    /// descriptor is gone either way and the identity is already durable.
    func persist(_ identity: StoredIdentity) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Self.directoryMode]
        )
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL, Self.identityMode)
        }
        guard descriptor >= 0 else {
            throw IdentityError.cannotWrite(path: url.path, code: errno)
        }
        do {
            try Self.writeAll(try JSONEncoder().encode(identity), to: descriptor, at: url.path)
            // Before the close, so an identity a peer may pin in the next
            // second is on the disk and not only in the page cache.
            guard fsync(descriptor) == 0 else {
                throw IdentityError.cannotWrite(path: url.path, code: errno)
            }
        } catch {
            // The only path that unlinks, and the only path that closes here:
            // `close(2)` releases the descriptor even when it reports an
            // error, so closing it a second time would close whatever number
            // the kernel has since handed to a NIO or SQLite thread.
            _ = close(descriptor)
            _ = url.withUnsafeFileSystemRepresentation { path in path.map { unlink($0) } }
            throw error
        }
        if close(descriptor) != 0 {
            // Reported and not thrown: `fsync` has already returned, so the
            // identity is durable and the caller has nothing to retry.
            logger.warning(
                "the device key was written but its descriptor did not close cleanly",
                metadata: [
                    "path": .string(url.path),
                    "error": .string(String(cString: strerror(errno))),
                ]
            )
        }
        syncParentDirectory()
    }

    /// `fsync`s the directory holding `device.key`, so the *name* is durable
    /// and not only the bytes.
    ///
    /// A file's contents and its directory entry are separately durable. Losing
    /// the entry to a power cut leaves `device.key` absent on the next start,
    /// which is not a read failure — ``localIdentity()`` treats it as "no identity yet"
    /// and generates a new one, giving this machine a fresh `SyncDeviceID` and
    /// silently un-pairing it from every peer that had pinned the old one. That
    /// is the exact outcome the exclusive create and the `fsync` above exist to
    /// prevent, so the entry gets the same treatment the contents do.
    ///
    /// Logged rather than thrown, like the `close`: the bytes are already on
    /// the disk, the identity in memory is the one this process will use, and
    /// there is nothing for the caller to retry. Deliberately outside the
    /// `do` above so it cannot reach the unlink path, which at this point would
    /// destroy a key a peer may already have pinned.
    private func syncParentDirectory() {
        let directory = url.deletingLastPathComponent()
        let descriptor = directory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_DIRECTORY)
        }
        guard descriptor >= 0 else {
            logger.warning(
                "the device key was written but its directory could not be opened to flush",
                metadata: [
                    "path": .string(directory.path),
                    "error": .string(String(cString: strerror(errno))),
                ]
            )
            return
        }
        if fsync(descriptor) != 0 {
            logger.warning(
                "the device key was written but its directory entry was not flushed",
                metadata: [
                    "path": .string(directory.path),
                    "error": .string(String(cString: strerror(errno))),
                ]
            )
        }
        _ = close(descriptor)
    }

    /// `write(2)` until every byte has landed.
    ///
    /// One call can write fewer bytes than it was given, and the short write is
    /// how a full disk truncates a key rather than failing outright.
    private static func writeAll(_ data: Data, to descriptor: Int32, at path: String) throws {
        var written = 0
        while written < data.count {
            let count: Int = data.withUnsafeBytes { buffer in
                write(descriptor, buffer.baseAddress?.advanced(by: written), data.count - written)
            }
            guard count > 0 else {
                // EINTR is a signal arriving mid-write, not a failure; every
                // other negative return is, and a zero-byte write on a regular
                // file has nowhere left to put the bytes.
                if count < 0, errno == EINTR { continue }
                throw IdentityError.cannotWrite(path: path, code: count < 0 ? errno : ENOSPC)
            }
            written += count
        }
    }
}

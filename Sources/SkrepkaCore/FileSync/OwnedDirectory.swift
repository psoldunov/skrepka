import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif
// For `stat`'s members in the static release build — see `OpenedFile.swift`.
#if canImport(CoreFoundation)
    import CoreFoundation
#endif

/// A directory this user made and nobody can redirect: created `0700` if it
/// is missing, and refused if what stands at the path is a symlink, anything
/// but a directory, or owned by someone else.
///
/// What a peer's files are written under has to be checked with `lstat`, not
/// `stat`: a `files/<hash>` planted as a symlink to `~/.ssh` is a directory by
/// `stat`, and every write "inside the cache" would land beside the keys.
enum OwnedDirectory {
    static func prepare(_ url: URL) throws {
        var status = stat()
        if lstat(url.path, &status) != 0 {
            guard errno == ENOENT else { throw FileMaterializer.Failure.untrustedDirectory(url.path) }
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            guard lstat(url.path, &status) == 0 else {
                throw FileMaterializer.Failure.untrustedDirectory(url.path)
            }
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR, status.st_uid == geteuid() else {
            throw FileMaterializer.Failure.untrustedDirectory(url.path)
        }
    }
}

import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif
// For the `stat` struct's members: on Linux the type is re-exported, and Swift
// 6's MemberImportVisibility wants the module that declares `st_mode` and
// `st_size`, which there is CoreFoundation — see `Daemon+Diagnostics.swift`.
// The debug build finds it transitively; the static release build that makes
// the Steam Deck tarball does not.
#if canImport(CoreFoundation)
    import CoreFoundation
#endif

/// One regular file's bytes, read through a single descriptor.
///
/// Stat-by-path then read-by-path is two lookups, and the path can change
/// between them: a FIFO swapped in blocks the read for ever, and a file that
/// grows reads past any size checked first. So the file is opened once —
/// non-blocking, so opening a FIFO returns at once, and without following a
/// symlink in the final component, which the caller has already resolved —
/// and every decision after that is made on the descriptor: `fstat` for its
/// type and size, and a read capped one byte past the budget, so a file that
/// grew is caught by the bytes actually read rather than trusted to its stat.
enum OpenedFile {
    enum Outcome: Sendable, Hashable {
        case bytes(Data)
        /// Larger than the budget, by its stat or by what was read.
        case tooLarge
        /// Not openable, or open and not a regular file.
        case notARegularFile
    }

    static func read(_ url: URL, atMost budget: Int) -> Outcome {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return .notARegularFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            return .notARegularFile
        }
        guard Int(status.st_size) <= budget else { return .tooLarge }
        do {
            let bytes = try readAll(handle, atMost: budget + 1)
            return bytes.count <= budget ? .bytes(bytes) : .tooLarge
        } catch {
            // A read that failed part-way is a file this copy cannot carry;
            // the rest of the copy still travels.
            return .notARegularFile
        }
    }

    /// Reads until end of file or `cap` bytes, whichever is first.
    private static func readAll(_ handle: FileHandle, atMost cap: Int) throws -> Data {
        var bytes = Data()
        while bytes.count < cap {
            guard let chunk = try handle.read(upToCount: cap - bytes.count), !chunk.isEmpty else { break }
            bytes.append(chunk)
        }
        return bytes
    }
}

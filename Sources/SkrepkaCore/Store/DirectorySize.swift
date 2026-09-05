import Foundation

/// Adds up the files inside a copied folder.
///
/// A folder carries no size of its own — the number Finder shows in Get Info is
/// a walk of everything underneath, which is why Finder shows a spinner while
/// it counts. Skrepka cannot spin: the row has to appear the moment the copy
/// happens, so the walk is bounded by a deadline and gives up rather than
/// counting a whole disk.
///
/// The deadline bounds how many steps the walk takes, not how long any one step
/// lasts. A single `next()` against a hung mount blocks inside the file system
/// until the mount times out, and no Foundation call cancels that. What the
/// deadline buys is that a folder which merely *is* enormous stops quickly; the
/// unresponsive-volume case is handled by where this runs, not by this —
/// ``ThumbnailRenderer``, where a stall delays one row instead of stalling the
/// clipboard watcher or the picker.
enum DirectorySize {
    /// How long a single folder may be measured for.
    ///
    /// Measured on an SSD at roughly 50,000 entries per second, so this covers
    /// a folder of about 12,000 files — comfortably every folder a person
    /// copies on purpose, and not `~/Library`. It runs on ``ThumbnailRenderer``
    /// rather than the main actor, so what it delays is the new row appearing,
    /// not the interface; the watcher's own polling cadence is 200 ms.
    static let deadline: Duration = .milliseconds(250)

    /// Total bytes of every regular file under `url`, or nil when the deadline
    /// passed first.
    ///
    /// Nil rather than the running total on purpose. A partial sum is a wrong
    /// number that looks like a right one, and a row reading "412 MB" for a
    /// folder holding 60 GB is worse than a row that says nothing about size.
    ///
    /// The clock is read once per entry rather than once per batch. Batching it
    /// was cheaper by a rounding error — a `ContinuousClock` read is tens of
    /// nanoseconds against a `resourceValues` syscall — and it left a hole: a
    /// folder with fewer children than the batch was never checked at all,
    /// however slow the volume under it. Every entry now costs a comparison and
    /// the deadline means what it says.
    ///
    /// Symbolic links are counted at neither end: the enumerator does not
    /// descend through them, and a link itself is not a regular file, so a
    /// folder full of aliases does not report the size of their targets.
    /// Children the file system refuses to describe are skipped, so a folder
    /// containing something unreadable reports the rest rather than failing.
    static func byteCount(ofDirectoryAt url: URL, deadline: Duration = Self.deadline) -> Int? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: [],
                // Skipped rather than fatal: one unreadable subfolder should
                // not cost the size of everything beside it.
                errorHandler: { _, _ in true }
            )
        else { return nil }

        let clock = ContinuousClock()
        let start = clock.now
        var total = 0

        for case let child as URL in enumerator {
            if clock.now - start > deadline { return nil }
            guard let values = try? child.resourceValues(forKeys: keys),
                values.isRegularFile == true,
                let size = values.fileSize
            else { continue }
            total += size
        }
        return total
    }
}

import Foundation

/// Adds up the files inside a copied folder.
///
/// A folder carries no size of its own — the number Finder shows in Get Info is
/// a walk of everything underneath, which is why Finder shows a spinner while
/// it counts. Skrepka cannot spin: the row has to appear the moment the copy
/// happens, so the walk is bounded by a deadline and gives up rather than
/// holding the capture open.
enum DirectorySize {
    /// How long a single folder may be measured for.
    ///
    /// Measured on an SSD at roughly 50,000 entries per second, so this covers
    /// a folder of about 12,000 files — comfortably every folder a person
    /// copies on purpose, and not `~/Library`. It runs on ``ThumbnailRenderer``
    /// rather than the main actor, so what it delays is the new row appearing,
    /// not the interface; the poller's own cadence is 200 ms.
    static let deadline: Duration = .milliseconds(250)

    /// Entries between two clock reads. Often enough to stop near the deadline,
    /// rare enough that the reads themselves are not part of the measurement.
    ///
    /// It is also the floor on how early a walk can give up: a folder of fewer
    /// entries than this is always measured in full, whatever the deadline.
    static let checkInterval = 512

    /// Total bytes of every regular file under `url`, or nil when the deadline
    /// passed first.
    ///
    /// Nil rather than the running total on purpose. A partial sum is a wrong
    /// number that looks like a right one, and a row reading "412 MB" for a
    /// folder holding 60 GB is worse than a row that says nothing about size.
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
        var visited = 0

        for case let child as URL in enumerator {
            visited += 1
            if visited.isMultiple(of: checkInterval), clock.now - start > deadline { return nil }
            guard let values = try? child.resourceValues(forKeys: keys),
                values.isRegularFile == true,
                let size = values.fileSize
            else { continue }
            total += size
        }
        return total
    }
}

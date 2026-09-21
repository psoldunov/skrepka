// Files received from peers, and keeping them in step with the rows they
// belong to. Linux carries the same rule in `SQLiteHistoryStore+FileCache.swift`.
#if canImport(SwiftData)

    import Foundation
    import SkrepkaSync
    import SwiftData
    import os

    extension HistoryStore {
        /// Removes the materialised files of every row that no longer exists.
        /// Answers how many items' files went.
        ///
        /// Runs whenever a row is removed, and once at launch for anything a
        /// crash left behind. Cheap when nothing was ever materialised: the
        /// cache directory is listed first, and only the hashes found there
        /// are looked up.
        @discardableResult
        public func sweepFileCache() -> Int {
            guard let fileCache else { return 0 }
            let cached = fileCache.entries()
            guard !cached.isEmpty else { return 0 }
            do {
                let live = try context.fetch(
                    FetchDescriptor<ClipRecord>(predicate: #Predicate { cached.contains($0.contentHash) })
                )
                return fileCache.sweep(keeping: Set(live.map(\.contentHash)))
            } catch {
                // Kept rather than guessed at: removing files a live row still
                // needs is worse than leaving an orphan for the next sweep.
                SkrepkaLog.store.error("Could not sweep received files: \(error.localizedDescription)")
                return 0
            }
        }
    }

#endif

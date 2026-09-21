// Files received from peers, kept in step with the rows they belong to — the
// Linux counterpart of `HistoryStore+FileCache.swift`. Fenced to Linux with
// the rest of this directory (D-3).
#if os(Linux)

    import Foundation
    import Logging
    import SkrepkaSync

    extension SQLiteHistoryStore {
        /// Where files received from peers are written. Nil until the daemon
        /// sets it; from then on every removal of a row removes that row's
        /// files — see ``sweepFileCache()``.
        public func setFileCache(_ cache: FileCache?) {
            fileCache = cache
        }

        /// Removes the materialised files of every row that no longer exists.
        /// Answers how many items' files went.
        ///
        /// Runs after deletion, clearing, eviction and every applied merge
        /// plan, and once at launch for anything a crash left behind. Cheap
        /// when nothing was ever materialised: the cache directory is listed
        /// before the database is asked anything.
        @discardableResult
        public func sweepFileCache() -> Int {
            guard let fileCache, !fileCache.entries().isEmpty else { return 0 }
            do {
                var live: Set<String> = []
                try database.query("SELECT content_hash FROM clip") { statement in
                    if let hash = statement.text(0) { live.insert(hash) }
                }
                return fileCache.sweep(keeping: live)
            } catch {
                // Kept rather than guessed at: removing files a live row still
                // needs is worse than leaving an orphan for the next sweep.
                SkrepkaLog.store.error("Could not sweep received files: \(error.localizedDescription)")
                return 0
            }
        }
    }

#endif

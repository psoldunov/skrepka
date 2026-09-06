// Eviction, split from HistoryStore.swift so the store there stays under the
// file ceiling. Linux gets a separate SQLite conformance in `Store/SQLite/`,
// which carries the same rule in `SQLiteHistoryStore.applyRetention()` (D-3, D-9).
#if canImport(SwiftData)

    import Foundation
    import SwiftData
    import os

    extension HistoryStore {
        /// Evicts entries past the retention cap.
        ///
        /// **This writes no tombstones, and that is the point.** It is one file
        /// away from ``delete(_:)`` and the difference is invisible to anyone who
        /// does not already know it matters, so: eviction is not deletion. Absence
        /// means "evicted here", and a peer re-offering an evicted clip is correct
        /// — the local cap simply re-evicts it. Writing a tombstone here would
        /// make a 500-item cap on this machine wipe a peer configured to keep
        /// 5000, permanently, and the user never asked for that. `MergeEngine` is
        /// built on the same rule from the other side.
        ///
        /// Anything that starts writing tombstones from this method is a bug, not
        /// a fix.
        func applyRetention() {
            let doomed = retention.idsToEvict(from: items)
            guard !doomed.isEmpty else { return }
            do {
                try context.delete(model: ClipRecord.self, where: #Predicate { doomed.contains($0.id) })
                try context.save()
                // The evicted id set is the delta, so the list is edited rather
                // than rebuilt — see ``project(upserts:removals:)``.
                project(removals: doomed)
            } catch {
                SkrepkaLog.store.error("Failed to apply retention: \(error.localizedDescription)")
            }
        }
    }

#endif

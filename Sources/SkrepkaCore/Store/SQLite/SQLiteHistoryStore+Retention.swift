// Retention as something the daemon changes while it runs, split from
// SQLiteHistoryStore.swift where the cap itself is applied. Fenced to Linux
// with the rest of this directory (D-3).
#if os(Linux)

    import Foundation

    extension SQLiteHistoryStore {
        /// The policy eviction runs against now.
        public var retentionPolicy: RetentionPolicy { retention }

        /// Replaces the retention policy and applies it at once.
        ///
        /// At once rather than at the next copy: a user who lowers the cap from
        /// 5000 to 100 expects the history to hold 100 entries when the window
        /// closes, not on some later copy they may never make. Evicts exactly as
        /// capture does — no tombstones, see ``applyRetention(now:)`` — so a
        /// lower cap here never reaches into a peer's history.
        ///
        /// - Returns: how many entries the new policy evicted.
        @discardableResult
        public func setRetention(_ policy: RetentionPolicy, now: Date = Date()) throws -> Int {
            retention = policy
            return try applyRetention(now: now)
        }

        /// Applies the current policy without anything having been captured.
        ///
        /// Capture is the only other place retention runs, so on an idle
        /// machine an age limit would never age anything out. The daemon calls
        /// this at start and on a timer. Same eviction, same absence of
        /// tombstones.
        ///
        /// - Returns: how many entries it evicted.
        @discardableResult
        public func sweepRetention(now: Date = Date()) throws -> Int {
            try applyRetention(now: now)
        }

        /// What the history holds, for the Settings window's figures.
        ///
        /// Pictures are counted by ``ClipSummary/isPicture``, the same rule the
        /// macOS History pane counts by.
        public func counts() throws -> HistoryCounts {
            let all = try summaries()
            return HistoryCounts(
                entries: all.count,
                pinned: all.count(where: \.isPinned),
                pictures: all.count(where: \.isPicture)
            )
        }

        /// How many entries, pinned entries and pictures the history holds.
        public struct HistoryCounts: Sendable, Hashable {
            public let entries: Int
            public let pinned: Int
            public let pictures: Int
        }
    }

#endif

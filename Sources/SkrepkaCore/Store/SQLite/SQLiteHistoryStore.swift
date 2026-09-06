// Raw SQLite is the Linux persistence engine (D-3); macOS never resolves the
// CSQLite target, so every file in this directory is fenced to Linux.
#if os(Linux)

    import Foundation
    import Logging
    import SkrepkaSync

    /// The clipboard history on Linux: persistence, de-duplication, pinning and
    /// eviction, over raw SQLite.
    ///
    /// The second conformance of `HistoryStoring`, beside the SwiftData
    /// `HistoryStore` macOS keeps ([D-3](../../../../docs/linux-sync/open-questions.md),
    /// D-9). Behaviour is the specification, not the implementation: what these
    /// methods do is whatever `HistoryStoringTests` asserts of both engines.
    ///
    /// An `actor` because one SQLite connection is one resource and the Phase 6
    /// daemon will drive it from several tasks. Isolation — not the library's own
    /// serialised mode — is what keeps two of them off the handle; the mutex is
    /// belt and braces for `deinit`. See ``SQLiteDatabase``.
    ///
    /// The sync surface is in `SQLiteHistoryStore+Sync.swift`, the receiving half
    /// in `+Merge.swift`, and paired peers in `+Pairing.swift`.
    public actor SQLiteHistoryStore {
        let database: SQLiteDatabase
        let retention: RetentionPolicy

        /// This device's sync identity, once it has one.
        ///
        /// `nil` until the sync stack loads or generates a certificate, exactly as
        /// on macOS: the store still captures, pins and deletes, but it stamps no
        /// origin device on new rows, writes no tombstones, and
        /// ``syncIndex(since:)`` throws
        /// ``HistoryStoreSyncError/deviceIdentityUnavailable``.
        public private(set) var localDeviceID: SyncDeviceID?

        /// - Parameter location: where the database lives, or nil for a private
        ///   in-memory one that dies with this instance (used by tests).
        public init(
            location: URL?,
            retention: RetentionPolicy = .default,
            localDeviceID: SyncDeviceID? = nil
        ) throws {
            self.retention = retention
            self.localDeviceID = localDeviceID

            if let location { try Self.prepareOnDisk(location) }
            database = try SQLiteDatabase(path: location?.path ?? ":memory:")
            try HistorySchema.install(on: database)
        }

        /// Creates the data directory and the database file the connection is about
        /// to open, both restricted to the user who owns them.
        ///
        /// This file is the plainest copy of everything the user has ever copied:
        /// `clip."text"` and `clip_representation.bytes` hold it in the clear, and
        /// D-7 keeps concealed content off the wire without keeping it out of here.
        /// `SkrepkaSync`'s `TrustStore` states the standard the repository holds
        /// itself to — 0600, and *created* with it — about a device key that leaks
        /// far less than this does. Without it, Debian's default `DIR_MODE=0755` on
        /// `/home` leaves `~/.local/share/skrepka` world-readable and every other
        /// account on the machine is one `sqlite3 … 'SELECT "text" FROM clip'` away
        /// from the whole history.
        ///
        /// The file is created empty and left for `sqlite3_open_v2` to find, rather
        /// than opened first and tightened after: SQLite reads a zero-length file as
        /// an empty database, so the connection never chooses a mode for it. Nothing
        /// is exposed in between either way — the file holds no byte of history
        /// until the schema is installed, which happens after this returns.
        ///
        /// The `-wal` and `-shm` sidecars are SQLite's to create and it derives
        /// their mode from the database file's. Asserted rather than assumed, by
        /// `SQLiteHistoryStoreTests.anOnDiskStoreIsReadableOnlyByItsOwner`.
        private static func prepareOnDisk(_ location: URL) throws {
            let manager = FileManager.default
            try manager.createDirectory(
                at: location.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            // An existing database is left alone: re-creating it would truncate the
            // history, and its mode was chosen when it was first made.
            guard !manager.fileExists(atPath: location.path) else { return }
            guard
                manager.createFile(
                    atPath: location.path,
                    contents: nil,
                    attributes: [.posixPermissions: NSNumber(value: 0o600)]
                )
            else {
                // `createFile` reports failure as `false` and swallows the reason,
                // so this says what was being attempted instead of guessing why.
                throw LocationError.cannotCreateStoreFile(path: location.path)
            }
        }

        /// What the store refuses to open rather than open unsafely.
        public enum LocationError: Error, Equatable {
            /// The database file could not be created with owner-only permissions.
            ///
            /// Thrown rather than falling through to `sqlite3_open_v2`, which would
            /// create the file itself at whatever the umask allows — the exact
            /// exposure ``prepareOnDisk(_:)`` exists to close.
            case cannotCreateStoreFile(path: String)
        }

        public func setLocalDeviceID(_ deviceID: SyncDeviceID?) {
            localDeviceID = deviceID
        }

        // MARK: - Reading

        /// Newest first, pinned entries hoisted to the top.
        ///
        /// Computed on demand rather than published: there is no SwiftUI on this
        /// platform to publish to, and the Phase 6 daemon asks for a snapshot when
        /// it needs one.
        ///
        /// The hoist is ``ClipProjection`` rather than an `ORDER BY is_pinned
        /// DESC`, so it is literally the same code macOS runs on the same list —
        /// one fewer place for the two engines to disagree. macOS maintains that
        /// projection by delta because it publishes it to SwiftUI on every
        /// mutation; here there is nothing to publish to, so it is built fresh
        /// each time it is asked for.
        ///
        /// `rowid ASC` is the tie-break, and it is chosen rather than natural: two
        /// rows sharing a `created_at` come back in insertion order, which is what
        /// SwiftData was *measured* doing for the same sort (`["first", "second",
        /// "third"]` where `rowid DESC` gave the reverse). SwiftData does not
        /// document a tie-break, so `HistoryStoringTests.orderingIsTheSameOnEveryRead`
        /// asserts the order on both engines: if the framework ever changes its
        /// mind, that fails on macOS instead of the two stores silently disagreeing
        /// about what the top of the history is.
        public func summaries() throws -> [ClipSummary] {
            let rows = try clipRows(.everything, trailing: "ORDER BY created_at DESC, rowid ASC")
            return ClipProjection(ordered: rows.map(SQLiteClipMapping.summary(from:))).items
        }

        /// Loads everything an entry needs to be pasted. Only called when
        /// something is pasted.
        ///
        /// `nil` means no such entry. An entry that exists but holds no bytes —
        /// learned from a peer, never fetched — is an empty ``ClipPayload``, which
        /// is a different answer and the same one macOS gives.
        ///
        /// The payload and the file list together, matching `HistoryStore`: a
        /// copy of several files pastes as several items and the payload carries
        /// only the first — see ``ClipContents``.
        public func contents(for id: UUID) -> ClipContents? {
            do {
                guard let row = try clipRow(id: id) else { return nil }
                return ClipContents(
                    payload: SQLiteRepresentationMapping.payload(
                        from: try representationRows(clipID: id)
                    ),
                    fileURLs: SQLiteClipMapping.fileURLs(from: row)
                )
            } catch {
                SkrepkaLog.store.error("Failed to load payload: \(error.localizedDescription)")
                return nil
            }
        }

        // MARK: - Mutation

        /// Flips the pin and stamps the last-writer-wins register that carries it
        /// to peers.
        ///
        /// Writing `is_pinned` alone would leave the register frozen at whatever
        /// wrote it last, so the pin would never win a merge and the change would
        /// silently fail to propagate.
        public func togglePin(_ id: UUID) {
            do {
                try database.run(
                    """
                    UPDATE clip
                    SET is_pinned = CASE WHEN is_pinned = 0 THEN 1 ELSE 0 END,
                        pinned_at = ?,
                        pinned_by = ?
                    WHERE id = ?
                    """,
                    [.value(Date()), .value(localDeviceID?.hex), .value(id)]
                )
            } catch {
                SkrepkaLog.store.error("Failed to update entry: \(error.localizedDescription)")
            }
        }

        public func delete(_ id: UUID) {
            do {
                try database.transaction {
                    guard let row = try clipRow(id: id) else { return }
                    try database.run("DELETE FROM clip WHERE id = ?", [.value(id)])
                    // A deletion is a fact peers have to learn, or the next sync
                    // brings it straight back. Eviction is not — see
                    // applyRetention(). The whole row rather than its hash: a
                    // concealed entry earns no tombstone, and `isConcealed` is
                    // the only thing that says so.
                    try recordDeletions(of: [row])
                }
            } catch {
                // The removal and its tombstone land together or not at all: a row
                // deleted without one is a row the next sync brings back. The
                // transaction has already rolled back, which leaves the entry
                // visible — something the user can act on, unlike silent
                // resurrection.
                SkrepkaLog.store.error("Failed to delete entry: \(error.localizedDescription)")
            }
            // Deletion is what grows the tombstone table, so it is what clears it.
            // Outside the transaction above: tidying must not roll back a removal
            // the user asked for.
            pruneExpiredTombstones()
        }

        /// Removes everything, optionally sparing pinned entries.
        public func clear(keepingPinned: Bool = true) {
            let condition = keepingPinned ? " WHERE is_pinned = 0" : ""
            do {
                try database.transaction {
                    // The rows have to be read before they go: clearing history is
                    // a deletion, so it writes a tombstone per row. Rows rather
                    // than hashes because a concealed entry earns no tombstone —
                    // its hash is a probe for the content itself, and a peer that
                    // never held it has nothing to delete.
                    let doomed = try clipRows(keepingPinned ? .unpinned : .everything)
                    try database.run("DELETE FROM clip\(condition)")
                    try recordDeletions(of: doomed)
                }
            } catch {
                // Same reason as delete(_:): rows and tombstones land together or
                // not at all.
                SkrepkaLog.store.error("Failed to clear history: \(error.localizedDescription)")
            }
            // Same reason as delete(_:), and the path that writes the most of them
            // at once.
            pruneExpiredTombstones()
        }

        /// Evicts entries past the retention cap.
        ///
        /// **This writes no tombstones, and that is the point.** It is one line
        /// away from ``delete(_:)`` in this file and the difference is invisible to
        /// anyone who does not already know it matters, so: eviction is not
        /// deletion. Absence means "evicted here", and a peer re-offering an
        /// evicted clip is correct — the local cap simply re-evicts it. Writing a
        /// tombstone here would make a 500-item cap on this machine wipe a peer
        /// configured to keep 5000, permanently, and the user never asked for that.
        ///
        /// Anything that starts writing tombstones from this method is a bug, not
        /// a fix.
        func applyRetention() throws {
            let doomed = retention.idsToEvict(from: try summaries())
            guard !doomed.isEmpty else { return }
            try database.transaction {
                for id in doomed {
                    try database.run("DELETE FROM clip WHERE id = ?", [.value(id)])
                }
            }
        }
    }

#endif

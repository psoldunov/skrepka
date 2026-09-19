// SwiftData only. A Mac is the only machine Universal Clipboard stages files
// on, so the Mac store is the only one a capture ever wrote a relay into. A
// Linux store holds relays only as an older Mac synced them, and the tombstones
// written here remove them there too.
#if canImport(SwiftData)

    import Foundation
    import SkrepkaSync
    import SwiftData
    import os

    extension HistoryStore {
        /// Removes every entry that holds nothing but files Universal Clipboard
        /// staged, and answers how many went — nil when the removal failed and
        /// nothing changed.
        ///
        /// Capture no longer records a relay and sync no longer accepts one — see
        /// `UniversalClipboardRelay` — so this is for what earlier builds left
        /// behind: a second row for every screenshot copied on the other Mac,
        /// recorded there as a relay and synced here beside the original.
        ///
        /// **A deletion like any other, tombstones and all.** The peer that sent
        /// these still holds them and would offer them again on the next
        /// exchange; the tombstones stop that and remove its copies as well. So
        /// this has to run once the store has a ``localDeviceID`` to write them
        /// with.
        ///
        /// Pinned entries stay. A pin is somebody asking to keep a row, and what
        /// this removes is duplicates nobody asked for.
        ///
        /// Reads the payload of every unpinned file entry learned from a peer,
        /// because that is the only place such a row keeps its path. That read
        /// runs off the main actor — see ``UniversalClipboardRelayScan`` — and it
        /// is still the cost that makes this a one-off for the caller rather
        /// than a pass on every launch.
        @discardableResult
        public func removeUniversalClipboardRelays() async -> Int? {
            let found: [UUID]
            do {
                found = try await UniversalClipboardRelayScan(container: container).relayIDs()
            } catch {
                SkrepkaLog.store.error(
                    "Failed to look for Universal Clipboard relays: \(error.localizedDescription)"
                )
                return nil
            }
            guard !found.isEmpty else { return 0 }
            return removeRelays(withIDs: found)
        }

        /// Deletes the rows the scan found, with a tombstone for each.
        ///
        /// Fetched again, and unpinned, because the scan read the store as it
        /// was saved before the await: a row pinned or deleted since is no
        /// longer this pass's to remove.
        private func removeRelays(withIDs found: [UUID]) -> Int? {
            let removed: Int
            do {
                let relays = try context.fetch(
                    FetchDescriptor<ClipRecord>(
                        predicate: #Predicate { !$0.isPinned && found.contains($0.id) })
                )
                guard !relays.isEmpty else { return 0 }
                // Read before the rows go, as `clear(keepingPinned:)` does.
                let deletions = relays.map { (contentHash: $0.contentHash, isConcealed: $0.isConcealed) }
                let ids = Set(relays.map(\.id))
                for record in relays {
                    context.delete(record)
                }
                try recordDeletions(of: deletions)
                try context.save()
                project(removals: ids)
                removed = relays.count
            } catch {
                // Rows and tombstones land together or not at all, for the reason
                // `delete(_:)` gives: a row removed without its tombstone comes
                // straight back on the next sync.
                context.rollback()
                reload()
                SkrepkaLog.store.error(
                    "Failed to remove Universal Clipboard relays: \(error.localizedDescription)"
                )
                return nil
            }
            // After the save, as the other deletion paths do: tidying must not
            // roll back a removal that has landed.
            pruneExpiredTombstones()
            return removed
        }
    }

#endif

// SwiftData is the macOS persistence engine and stays that way (D-3, D-9). Linux
// gets a separate SQLite conformance of HistoryStoring in Phase 4 storage work,
// not a second @Model.
#if canImport(SwiftData)

    import Foundation
    import SwiftData

    /// The persisted shape of a deletion.
    ///
    /// A tombstone names content, not a row: without one a re-sync resurrects
    /// everything the user deleted, and a `UUID` cannot survive the round trip
    /// because two machines that copied the same string generated different ones.
    ///
    /// **Eviction writes none of these.** A 500-item cap on one machine must not
    /// wipe a peer configured to keep 5000 — see `HistoryStore.applyRetention()`.
    ///
    /// Thin, like ``ClipRecord``: mapped to `SkrepkaSync.Tombstone` at the store
    /// boundary by ``TombstoneRecordMapping``.
    @Model
    final class TombstoneRecord {
        /// The same identity items use.
        var contentHash: String = ""
        var deletedAt: Date = Date()
        /// `SyncDeviceID.hex` of the device that recorded the deletion. Stored as
        /// a string for the same reason `ClipRecord.pinnedBy` is.
        var deviceIDHex: String = ""

        init(contentHash: String, deletedAt: Date, deviceIDHex: String) {
            self.contentHash = contentHash
            self.deletedAt = deletedAt
            self.deviceIDHex = deviceIDHex
        }
    }

#endif

// Maps the SwiftData TombstoneRecord, so it belongs to that conformance. The
// Linux SQLite store writes its own mapping in Phase 4 storage work (D-9).
#if canImport(SwiftData)

    import Foundation
    import SkrepkaSync

    /// Conversions between the persisted ``TombstoneRecord`` and the
    /// `SkrepkaSync` value type the wire and the merge engine speak.
    enum TombstoneRecordMapping {
        /// `nil` when ``TombstoneRecord/deviceIDHex`` is not a device identifier.
        ///
        /// Failing rather than substituting: a tombstone's device is half of its
        /// tie-break, so inventing one would let two peers resolve the same
        /// deletion differently. The caller logs and skips the row.
        static func tombstone(from record: TombstoneRecord) -> Tombstone? {
            guard let deviceID = SyncDeviceID(hex: record.deviceIDHex) else { return nil }
            return Tombstone(
                contentHash: record.contentHash,
                deletedAt: record.deletedAt,
                deviceID: deviceID
            )
        }

        static func makeRecord(from tombstone: Tombstone) -> TombstoneRecord {
            TombstoneRecord(
                contentHash: tombstone.contentHash,
                deletedAt: tombstone.deletedAt,
                deviceIDHex: tombstone.deviceID.hex
            )
        }
    }

#endif

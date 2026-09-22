// What the Mac app needs to know about a row before it writes a file copy to
// the pasteboard: whether this device recorded it, and whether the files came.
// SwiftData only; the Linux daemon reads the same facts from its own store.
#if canImport(SwiftData)

    import Foundation
    import SkrepkaSync
    import SwiftData
    import os

    extension HistoryStore {
        /// Who recorded a row, as a paste needs it.
        public struct RowOrigin: Sendable, Hashable {
            /// The row's identity across devices, and the name of the directory
            /// its received files are written to — see ``FileCache``.
            public let contentHash: String
            /// Whether another device recorded the row. A foreign file row's
            /// paths belong to that device and must never reach this pasteboard.
            public let isForeign: Bool

            public init(contentHash: String, isForeign: Bool) {
                self.contentHash = contentHash
                self.isForeign = isForeign
            }
        }

        /// The row's origin, or nil when it is gone or cannot be read.
        public func origin(for id: UUID) -> RowOrigin? {
            do {
                guard let record = try record(withID: id) else { return nil }
                return RowOrigin(contentHash: record.contentHash, isForeign: isForeign(record))
            } catch {
                SkrepkaLog.store.error("Failed to read an entry's origin: \(error.localizedDescription)")
                return nil
            }
        }

        /// Whether a file row from another device carries its files, or nil for
        /// any other row — see
        /// ``SyncedFilesStatus/of(kind:isForeign:offeredTypes:heldTypes:offeredBundleBytes:fileLimit:)``.
        ///
        /// The payload is read only when the peer offered a bundle, which is the
        /// one case where what is held decides the answer.
        public func syncedFilesStatus(
            for id: UUID,
            fileLimit: Int = FileSyncLimit.ceiling
        ) -> SyncedFilesStatus? {
            do {
                guard let record = try record(withID: id) else { return nil }
                let kind = ClipKind(rawValue: record.kindRaw) ?? .text
                guard kind.isFileSystemEntry, isForeign(record) else { return nil }
                let index = try RepresentationIndex.decode(record.representationIndex ?? Data())
                let offered = Set(index.keys)
                let held: Set<String> =
                    offered.contains(FileBundle.storageType)
                    ? Set(try ClipRecordMapping.decodePayload(record.payloadData).representations.keys)
                    : []
                return SyncedFilesStatus.of(
                    kind: kind,
                    isForeign: true,
                    offeredTypes: offered,
                    heldTypes: held,
                    offeredBundleBytes: index[FileBundle.storageType],
                    fileLimit: fileLimit
                )
            } catch {
                SkrepkaLog.store.error("Failed to read an entry's files: \(error.localizedDescription)")
                return nil
            }
        }

        /// Whether another device recorded `record`.
        ///
        /// Compared against this device's identity once sync has loaded it.
        /// Before that — sync off since launch — a row learned from a peer is
        /// told apart by the file list: a local capture stores its own paths,
        /// and a row made from a peer's offer never has any.
        private func isForeign(_ record: ClipRecord) -> Bool {
            guard let origin = record.originDeviceID else { return false }
            if let localDeviceID { return origin != localDeviceID.hex }
            return record.fileURLStrings == nil
        }
    }

#endif

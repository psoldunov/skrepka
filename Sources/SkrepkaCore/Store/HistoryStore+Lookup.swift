// SwiftData only; the Linux daemon names entries by content hash throughout.
#if canImport(SwiftData)

    import Foundation
    import os

    extension HistoryStore {
        /// The entry a content hash names, or nil when there is none.
        ///
        /// For a transfer, which knows its item only by the hash it has on
        /// both machines, to find the row the picker draws it on.
        public func entryID(forContentHash contentHash: String) -> UUID? {
            do {
                return try recordMatching(contentHash: contentHash)?.id
            } catch {
                SkrepkaLog.store.error(
                    "Failed to find an entry by content hash: \(error.localizedDescription)")
                return nil
            }
        }
    }

#endif

// SwiftData only, as `HistoryStore+Relays.swift` is — see there for why.
#if canImport(SwiftData)

    import Foundation
    import SkrepkaSync
    import SwiftData

    /// Finds the Universal Clipboard relays earlier builds recorded, off the
    /// main actor — see `HistoryStore.removeUniversalClipboardRelays()`.
    ///
    /// An actor because the question can only be answered from payloads, and a
    /// row learned from a peer keeps a screenshot's picture in its payload
    /// beside the path. Reading every one of those on the main actor stalled
    /// the app the first time sync came up.
    ///
    /// Reads through a context of its own, made for each scan and never kept:
    /// the main context belongs to the main actor, and a context is only safe
    /// on the one isolation domain that uses it.
    actor UniversalClipboardRelayScan {
        private let container: ModelContainer

        init(container: ModelContainer) {
            self.container = container
        }

        /// The ids of every unpinned entry that holds nothing but staged files,
        /// as the store stood when it was last saved.
        func relayIDs() throws -> [UUID] {
            let context = ModelContext(container)
            let kinds = ClipKind.allCases.filter(\.isFileSystemEntry).map(\.rawValue)
            let records = try context.fetch(
                FetchDescriptor<ClipRecord>(
                    predicate: #Predicate { !$0.isPinned && kinds.contains($0.kindRaw) }
                )
            )
            return records.filter(Self.isRelay).map(\.id)
        }

        /// Whether every file a row names is staged.
        ///
        /// A local capture stores its files beside the payload. A row learned
        /// from a peer does not — the paths are the other machine's — so its
        /// payload's one file URL is all there is to read.
        private static func isRelay(_ record: ClipRecord) -> Bool {
            let stored = ClipRecordMapping.fileURLs(from: record)
            guard stored.isEmpty else { return UniversalClipboardRelay.holdsOnlyStagedFiles(stored) }
            // A payload that will not decode names no file, so the row is kept:
            // the question here is only whether it is a relay, and nothing
            // unreadable can show that it is.
            let payload = try? ClipRecordMapping.decodePayload(record.payloadData)
            return UniversalClipboardRelay.holdsOnlyStagedFiles([payload?.fileURL].compactMap(\.self))
        }
    }

#endif

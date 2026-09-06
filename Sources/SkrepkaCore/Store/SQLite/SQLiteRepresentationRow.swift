// Raw SQLite is the Linux persistence engine (D-3); macOS never resolves the
// CSQLite target, so every file in this directory is fenced to Linux.
#if os(Linux)

    import Foundation
    import SkrepkaSync

    /// One row of `clip_representation` — the Linux answer to
    /// `@Attribute(.externalStorage)` plus `ClipRecord.representationIndex`.
    ///
    /// ``byteCount`` is what an index offer reports and ``bytes`` is what a fetch
    /// serves, and they are separate because an item learned from a peer knows the
    /// first long before it holds the second. `bytes == nil` is the protocol's
    /// documented "this store does not hold them", not a fault.
    ///
    /// Keys are the *platform's own* representation names, exactly as
    /// `RepresentationIndex` documents for the SwiftData side: `PasteboardType`
    /// raw values, which port to Linux unchanged. Mapping them to the wire's
    /// canonical media types is ``SQLiteClipMapping``'s job.
    struct SQLiteRepresentationRow: Sendable, Equatable {
        let type: String
        let byteCount: Int
        let bytes: Data?

        static let insert = """
            INSERT INTO clip_representation (clip_id, "type", byte_count, bytes) VALUES (?, ?, ?, ?)
            """

        func bindings(clipID: UUID) -> [SQLiteValue] {
            [.value(clipID), .value(type), .value(byteCount), .value(bytes)]
        }

        init(type: String, byteCount: Int, bytes: Data?) {
            self.type = type
            self.byteCount = byteCount
            self.bytes = bytes
        }

        /// Reads a row selected as `"type", byte_count, bytes`.
        init?(statement: SQLiteStatement) {
            guard let type = statement.text(0), let byteCount = statement.integer(1) else {
                return nil
            }
            self.type = type
            self.byteCount = byteCount
            bytes = statement.blob(2)
        }
    }

    // MARK: - Conversions

    /// Payload bytes in and out of ``SQLiteRepresentationRow``.
    ///
    /// Separate from ``SQLiteClipMapping`` because this half never touches the
    /// clip row: it is only ever about which representations exist, how large they
    /// are, and which of them this machine actually holds.
    enum SQLiteRepresentationMapping {
        /// Rows for something copied on this machine. Every representation is held,
        /// so every row carries its bytes.
        static func rows(from payload: ClipPayload) -> [SQLiteRepresentationRow] {
            payload.representations.map { type, data in
                SQLiteRepresentationRow(type: type, byteCount: data.count, bytes: data)
            }
        }

        /// Rows for content learned from a peer.
        ///
        /// Byte counts come from the metadata, which is eager; bytes come from
        /// whatever the transport chose to send with it, which is usually nothing
        /// (design §7). A descriptor with no local type is dropped rather than
        /// stored under an invented one — the same rule
        /// `SyncMetaMapping.index(from:)` applies, and for the same reason: a row
        /// naming a type no clipboard here can serve would have a peer fetch bytes
        /// it cannot read.
        static func rows(
            from meta: SyncClipMeta,
            payloads: [RepresentationKey: Data]
        ) -> [SQLiteRepresentationRow] {
            meta.representations.compactMap { descriptor in
                guard let type = RepresentationKeyMap.uti(forCanonical: descriptor.key.canonical) else {
                    return nil
                }
                return SQLiteRepresentationRow(
                    type: type,
                    byteCount: descriptor.byteCount,
                    bytes: payloads[descriptor.key]
                )
            }
        }

        /// The payload as the rest of the app reads it, from the representations
        /// this machine holds.
        ///
        /// A row whose bytes are absent is left out entirely rather than included
        /// as empty data: `ClipPayload` says what can be pasted, and an empty
        /// representation would paste nothing under a type that promised
        /// something.
        static func payload(from rows: [SQLiteRepresentationRow]) -> ClipPayload {
            var representations: [String: Data] = [:]
            for row in rows {
                guard let bytes = row.bytes else { continue }
                representations[row.type] = bytes
            }
            return ClipPayload(representations: representations)
        }

        /// Byte count per representation, keyed by local type — the shape
        /// `RepresentationIndex` holds on the SwiftData side.
        static func index(from rows: [SQLiteRepresentationRow]) -> [String: Int] {
            var index: [String: Int] = [:]
            for row in rows { index[row.type] = row.byteCount }
            return index
        }

        /// Local types that can serve `key`, best first.
        ///
        /// `origin` first because it is the sender's own name and is exact when the
        /// sender indexed itself the same way this store does. It is something else
        /// entirely when the sender did not, so the canonical mapping is the
        /// fallback that answers either way.
        static func localTypes(for key: RepresentationKey) -> [String] {
            [key.origin, RepresentationKeyMap.uti(forCanonical: key.canonical)].compactMap { $0 }
        }
    }

#endif

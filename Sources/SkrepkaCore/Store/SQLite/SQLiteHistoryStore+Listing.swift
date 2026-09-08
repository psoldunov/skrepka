// What a client outside this process needs to list the history. Fenced to Linux
// with the rest of the SQLite engine (D-3), and Linux-only for a second reason
// besides: the only caller is the Phase 6 daemon's D-Bus interface, and macOS
// has no equivalent client — its picker reads the store in-process and takes
// `ClipSummary` directly.
#if os(Linux)

    import Foundation

    extension SQLiteHistoryStore {
        /// One row, as something outside the process can name and act on it.
        ///
        /// ``ClipSummary`` alone is not enough for an IPC client, and the two
        /// missing pieces are both about acting rather than drawing:
        ///
        /// - **``contentHash``**, because it is the identity of a clip
        ///   everywhere else in Skrepka. A client that has listed the history
        ///   and wants to copy one entry needs a name for it that survives
        ///   another clip arriving in between, which a position does not.
        /// - **``representationTypes``**, because a client has to decide whether
        ///   it can do anything useful with an entry before asking for it — a
        ///   GNOME menu that offers to paste an image it cannot render is worse
        ///   than one that does not offer.
        ///
        /// Neither is added to `ClipSummary` itself. That type is read by the
        /// macOS picker twenty rows at a time and neither field would be used
        /// there, which is the test D-9 sets for a seam introduced for Linux:
        /// would this change be worth making if Linux did not exist?
        public struct ClipListing: Sendable, Hashable {
            public let summary: ClipSummary
            public let contentHash: String
            /// The stored representation identifiers, sorted. Pasteboard type
            /// identifiers as the store holds them, not canonical media types —
            /// mapping between the two belongs to `RepresentationKeyMap` and its
            /// caller, not to a storage read.
            public let representationTypes: [String]

            public init(summary: ClipSummary, contentHash: String, representationTypes: [String]) {
                self.summary = summary
                self.contentHash = contentHash
                self.representationTypes = representationTypes
            }
        }

        /// The whole history, newest first with pinned entries hoisted.
        ///
        /// Same order and same projection as ``summaries()``, because a daemon
        /// and a picker showing different orders for one history is exactly the
        /// drift `ClipProjection` exists to prevent. This is that method plus
        /// two joins, not a second ordering.
        ///
        /// **Concealed entries are included.** That is deliberate and it is not
        /// a leak of the kind D-7 governs: D-7 keeps concealed content off the
        /// *wire*, and this is the local user's own history read by the local
        /// user's own session bus. `summaries()` includes them too, and the
        /// macOS picker draws them. What no caller gets is the bytes without
        /// asking, and what no *peer* gets is either.
        public func listing() throws -> [ClipListing] {
            let rows = try clipRows(.everything, trailing: "ORDER BY created_at DESC, rowid ASC")
            let indexes = try representationIndexes(.everything)
            let hashes = Dictionary(rows.map { ($0.id, $0.contentHash) }) { first, _ in first }
            let ordered = ClipProjection(ordered: rows.map(SQLiteClipMapping.summary(from:))).items
            return ordered.map { summary in
                ClipListing(
                    summary: summary,
                    // A row that came out of `clipRows` always has a hash — the
                    // column is `NOT NULL` and `SQLiteClipRow` refuses to decode
                    // without one. The fallback is unreachable and is an empty
                    // string rather than a force-unwrap, because an unreachable
                    // crash is still a crash.
                    contentHash: hashes[summary.id] ?? "",
                    representationTypes: (indexes[summary.id]?.keys).map { $0.sorted() } ?? []
                )
            }
        }

        /// The row identifier for a content hash, or a prefix of one.
        ///
        /// Nil for no match. Throws ``ListingError/ambiguousPrefix(_:matching:)``
        /// for a prefix that matches more than one entry, rather than picking
        /// either: the entries a short prefix collides on hold unrelated
        /// content, and guessing means pasting something the user did not ask
        /// for.
        public func identifier(forContentHashPrefix prefix: String) throws -> UUID? {
            let lowered = prefix.lowercased()
            let matches = try clipRows(.everything).filter {
                $0.contentHash.hasPrefix(lowered)
            }
            guard matches.count <= 1 else {
                throw ListingError.ambiguousPrefix(prefix, matching: matches.count)
            }
            return matches.first?.id
        }

        public enum ListingError: Error, Sendable, Equatable, CustomStringConvertible {
            case ambiguousPrefix(String, matching: Int)

            public var description: String {
                switch self {
                case .ambiguousPrefix(let prefix, let count):
                    "\"\(prefix)\" matches \(count) entries — use more characters"
                }
            }
        }
    }

#endif

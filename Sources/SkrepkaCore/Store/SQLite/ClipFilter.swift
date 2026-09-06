// Raw SQLite is the Linux persistence engine (D-3); macOS never resolves the
// CSQLite target, so every file in this directory is fenced to Linux.
#if os(Linux)

    import Foundation

    /// A `WHERE` fragment and the values its placeholders bind.
    ///
    /// One value rather than two parameters because the two cannot be correct
    /// apart: a condition holding a `?` and an empty value list is a statement
    /// that binds nothing, which SQLite runs happily against `NULL`. Passing them
    /// separately is how that happens.
    ///
    /// Every condition here is SQL this module writes. Nothing a peer or a user
    /// typed reaches the statement text — that is what ``values`` is for.
    struct ClipFilter {
        let condition: String?
        let values: [SQLiteValue]

        init(condition: String?, values: [SQLiteValue] = []) {
            self.condition = condition
            self.values = values
        }

        static let everything = ClipFilter(condition: nil)

        static let unpinned = ClipFilter(condition: "is_pinned = 0")

        static func id(_ id: UUID) -> ClipFilter {
            ClipFilter(condition: "id = ?", values: [.value(id)])
        }

        static func contentHash(_ contentHash: String) -> ClipFilter {
            ClipFilter(condition: "content_hash = ?", values: [.value(contentHash)])
        }

        /// What may be offered to a peer: never concealed, and created after
        /// `cursor` when there is one.
        ///
        /// One definition, used by both halves of an index offer — the rows and
        /// their representation counts. They were two hand-written predicates that
        /// had to agree, and a comment saying so is weaker than not being able to
        /// write them differently.
        ///
        /// - Parameter qualifier: a table alias and its dot, for the query that
        ///   joins. Empty when the clip table is the only one named.
        static func syncable(since cursor: Date?, qualifier: String = "") -> ClipFilter {
            guard let cursor else {
                return ClipFilter(condition: "\(qualifier)is_concealed = 0")
            }
            return ClipFilter(
                condition: "\(qualifier)is_concealed = 0 AND \(qualifier)created_at > ?",
                values: [.value(cursor)]
            )
        }

        /// Both filters, narrowed together.
        ///
        /// Exists so ``syncable(since:qualifier:)`` stays the one statement of what
        /// a peer may be shown: serving one row by hash is that rule narrowed by an
        /// identity, not a second rule that happens to spell it the same way.
        ///
        /// Each side is parenthesised. Every condition in this type is a
        /// conjunction today, so it would read the same without them, and a future
        /// `OR` would silently change what a combined filter means.
        func and(_ other: ClipFilter) -> ClipFilter {
            let conditions = [condition, other.condition].compactMap { $0 }
            return ClipFilter(
                condition: conditions.isEmpty
                    ? nil : conditions.map { "(\($0))" }.joined(separator: " AND "),
                values: values + other.values
            )
        }
    }

#endif

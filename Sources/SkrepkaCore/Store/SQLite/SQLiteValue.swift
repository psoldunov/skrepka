// Raw SQLite is the Linux persistence engine (D-3); macOS never resolves the
// CSQLite target, so every file in this directory is fenced to Linux.
#if os(Linux)

    import Foundation

    /// One bound parameter, in the five storage classes SQLite has.
    ///
    /// An enum rather than overloaded `bind` methods so a statement's parameters
    /// arrive as one array in the order the SQL declares them. Binding by hand,
    /// index by index, is how a column ends up holding the value meant for its
    /// neighbour.
    enum SQLiteValue: Equatable {
        case null
        case integer(Int64)
        case double(Double)
        case text(String)
        case blob(Data)
    }

    // MARK: - Swift values

    /// One `value(_:)` per Swift type, each taking the optional form.
    ///
    /// Deliberately not overloaded on `T` and `T?` both: Swift resolves that pair
    /// by preferring the non-optional, which is correct and completely invisible,
    /// and a column that quietly stopped accepting `NULL` is the kind of drift
    /// this store cannot afford. A non-optional argument promotes to the optional
    /// parameter for free; a literal `nil` uses ``SQLiteValue/null``.
    extension SQLiteValue {
        static func value(_ text: String?) -> SQLiteValue { text.map(SQLiteValue.text) ?? .null }

        static func value(_ number: Int?) -> SQLiteValue {
            number.map { .integer(Int64($0)) } ?? .null
        }

        static func value(_ data: Data?) -> SQLiteValue { data.map(SQLiteValue.blob) ?? .null }

        /// Dates are stored as `timeIntervalSinceReferenceDate`, the same `Double`
        /// SwiftData writes, so a value round-trips exactly rather than merely
        /// closely — several assertions compare stored dates for equality.
        static func value(_ date: Date?) -> SQLiteValue {
            date.map { .double($0.timeIntervalSinceReferenceDate) } ?? .null
        }

        static func value(_ flag: Bool) -> SQLiteValue { .integer(flag ? 1 : 0) }

        /// UUIDs are stored as their uppercase string form. Sixteen raw bytes
        /// would be smaller, but the column gets read by hand during triage often
        /// enough that legibility is worth twenty bytes a row.
        static func value(_ id: UUID) -> SQLiteValue { .text(id.uuidString) }
    }

#endif

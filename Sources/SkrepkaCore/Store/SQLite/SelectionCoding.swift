// Raw SQLite is the Linux persistence engine (D-3); macOS never resolves the
// CSQLite target, so every file in this directory is fenced to Linux.
#if os(Linux)

    import Foundation

    /// The two list-shaped clip columns, as blobs and back.
    ///
    /// SwiftData stores `[String]?` and `[Data]?` on `ClipRecord` itself; SQLite
    /// has no array type, so the same two properties are one blob each here. A
    /// binary property list rather than JSON for the reason ``ClipRecordMapping``
    /// uses one for the payload: the icons are raw PNG bytes, and base64 in a
    /// column read on every row is a third again the size for nothing.
    ///
    /// Nil in, nil out, on both sides. A `NULL` column means what a `nil`
    /// property means on the other engine — "this row predates the column" — and
    /// an empty list is a different fact that neither store writes.
    enum SelectionCoding {
        /// The absolute URL strings of the files a row holds.
        static func encode(fileURLStrings: [String]?) throws -> Data? {
            guard let fileURLStrings else { return nil }
            return try encoder().encode(fileURLStrings)
        }

        static func decodeFileURLStrings(_ data: Data?) throws -> [String]? {
            guard let data, !data.isEmpty else { return nil }
            return try PropertyListDecoder().decode([String].self, from: data)
        }

        /// The PNG icons of a row's stack, front first.
        static func encode(stackIcons: [Data]?) throws -> Data? {
            guard let stackIcons else { return nil }
            return try encoder().encode(stackIcons)
        }

        static func decodeStackIcons(_ data: Data?) throws -> [Data]? {
            guard let data, !data.isEmpty else { return nil }
            return try PropertyListDecoder().decode([Data].self, from: data)
        }

        private static func encoder() -> PropertyListEncoder {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            return encoder
        }
    }

#endif

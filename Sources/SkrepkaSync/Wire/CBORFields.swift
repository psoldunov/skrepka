import Foundation

/// Typed, throwing access to a decoded CBOR map.
///
/// Exists so message decoding reads as a list of fields rather than a list of
/// pattern matches. Every accessor throws on a shape it did not expect, which
/// is what keeps `if case .text(let s) = value else { … }` — and the temptation
/// to write `try!` next to it — out of the message decoders.
struct CBORFields {
    private let fields: [CBORValue: CBORValue]
    /// Named in every error, so a failure says which message was malformed.
    private let context: String

    init(_ value: CBORValue, context: String) throws {
        guard case .map(let fields) = value else {
            throw CBORError.unexpectedShape("\(context) is not a map")
        }
        self.fields = fields
        self.context = context
    }

    /// Absent keys and explicit nulls are the same answer: the field was not
    /// sent. Optionals go on the wire as `null` rather than a missing key, so
    /// every message has one map shape — but tolerating both costs nothing and
    /// lets a field be dropped in a later revision.
    func value(_ key: String) -> CBORValue? {
        guard let value = fields[.text(key)], value != .null else { return nil }
        return value
    }

    func required(_ key: String) throws -> CBORValue {
        guard let value = value(key) else {
            throw CBORError.unexpectedShape("\(context) is missing \(key)")
        }
        return value
    }

    func string(_ key: String) throws -> String {
        guard case .text(let string) = try required(key) else {
            throw CBORError.unexpectedShape("\(context).\(key) is not a text string")
        }
        return string
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = value(key) else { return nil }
        guard case .text(let string) = value else {
            throw CBORError.unexpectedShape("\(context).\(key) is not a text string")
        }
        return string
    }

    func integer(_ key: String) throws -> Int64 {
        guard let integer = try required(key).integerValue else {
            throw CBORError.unexpectedShape("\(context).\(key) is not an integer")
        }
        return integer
    }

    func optionalInteger(_ key: String) throws -> Int64? {
        guard let value = value(key) else { return nil }
        guard let integer = value.integerValue else {
            throw CBORError.unexpectedShape("\(context).\(key) is not an integer")
        }
        return integer
    }

    /// An `Int` field, refused rather than truncated when the wire value does
    /// not fit this platform's word.
    func count(_ key: String) throws -> Int {
        guard let count = Int(exactly: try integer(key)) else {
            throw CBORError.unexpectedShape("\(context).\(key) does not fit in an Int")
        }
        return count
    }

    func optionalCount(_ key: String) throws -> Int? {
        guard let integer = try optionalInteger(key) else { return nil }
        guard let count = Int(exactly: integer) else {
            throw CBORError.unexpectedShape("\(context).\(key) does not fit in an Int")
        }
        return count
    }

    func boolean(_ key: String) throws -> Bool {
        guard case .boolean(let flag) = try required(key) else {
            throw CBORError.unexpectedShape("\(context).\(key) is not a boolean")
        }
        return flag
    }

    func bytes(_ key: String) throws -> Data {
        guard case .bytes(let data) = try required(key) else {
            throw CBORError.unexpectedShape("\(context).\(key) is not a byte string")
        }
        return data
    }

    func array(_ key: String) throws -> [CBORValue] {
        guard case .array(let elements) = try required(key) else {
            throw CBORError.unexpectedShape("\(context).\(key) is not an array")
        }
        return elements
    }

}

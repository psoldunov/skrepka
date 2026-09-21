import CGtk4

/// A small, ownership-safe value tree for the D-Bus types this app uses.
public indirect enum DBusValue: Sendable, Equatable {
    case boolean(Bool)
    case byte(UInt8)
    case int32(Int32)
    case uint32(UInt32)
    case uint64(UInt64)
    case double(Double)
    case string(String)
    case objectPath(String)
    case variant(DBusValue)
    case array(elementSignature: String, values: [DBusValue])
    case tuple([DBusValue])
    case dictionary([String: DBusValue])

    var stringValue: String? {
        switch self {
        case .string(let value), .objectPath(let value): value
        case .variant(let value): value.stringValue
        default: nil
        }
    }

    var int32Value: Int32? {
        switch self {
        case .int32(let value): value
        case .variant(let value): value.int32Value
        default: nil
        }
    }

    var uint32Value: UInt32? {
        switch self {
        case .uint32(let value): value
        case .variant(let value): value.uint32Value
        default: nil
        }
    }

    var children: [DBusValue]? {
        switch self {
        case .array(_, let values), .tuple(let values): values
        case .variant(let value): value.children
        default: nil
        }
    }

    var dictionaryValue: [String: DBusValue]? {
        switch self {
        case .dictionary(let value): value
        case .variant(let value): value.dictionaryValue
        default: nil
        }
    }
}

extension DBusValue {
    func makeVariant() -> OpaquePointer? {
        makeBasicVariant() ?? makeContainerVariant()
    }

    private func makeContainerVariant() -> OpaquePointer? {
        switch self {
        case .string(let value): return g_variant_new_string(value)
        case .objectPath(let value): return skrepka_variant_new_object_path(value)
        case .variant(let value):
            guard let nested = value.makeVariant() else { return nil }
            return g_variant_new_variant(nested)
        case .array(let signature, let values): return makeArray(signature: signature, values: values)
        case .tuple(let values): return makeTuple(values)
        case .dictionary(let values): return makeDictionary(values)
        default: return nil
        }
    }

    static func parse(_ variant: OpaquePointer) -> DBusValue? {
        let signature = String(cString: g_variant_get_type_string(variant))
        if let basic = parseBasic(variant, signature: signature) { return basic }
        switch signature {
        case "s": return .string(String(cString: g_variant_get_string(variant, nil)))
        case "o": return .objectPath(String(cString: g_variant_get_string(variant, nil)))
        case "v": return parseChild(variant, at: 0).map(DBusValue.variant)
        case "a{sv}": return parseDictionary(variant)
        default:
            guard signature.first == "(" || signature.first == "a" else { return nil }
            let values = parseChildren(variant)
            if signature.first == "(" { return .tuple(values) }
            return .array(elementSignature: arrayElement(of: signature), values: values)
        }
    }

    private func makeBasicVariant() -> OpaquePointer? {
        switch self {
        case .boolean(let value): skrepka_variant_new_boolean(value ? 1 : 0)
        case .byte(let value): skrepka_variant_new_byte(value)
        case .int32(let value): g_variant_new_int32(value)
        case .uint32(let value): skrepka_variant_new_uint32(value)
        case .uint64(let value): skrepka_variant_new_uint64(UInt(value))
        case .double(let value): skrepka_variant_new_double(value)
        default: nil
        }
    }

    private static func parseBasic(_ variant: OpaquePointer, signature: String) -> DBusValue? {
        switch signature {
        case "b": .boolean(g_variant_get_boolean(variant) != 0)
        case "y": .byte(g_variant_get_byte(variant))
        case "i": .int32(g_variant_get_int32(variant))
        case "u": .uint32(g_variant_get_uint32(variant))
        case "t": .uint64(UInt64(g_variant_get_uint64(variant)))
        case "d": .double(g_variant_get_double(variant))
        default: nil
        }
    }

    private func makeArray(signature: String, values: [DBusValue]) -> OpaquePointer? {
        var children: [OpaquePointer?] = []
        for value in values {
            guard let child = value.makeVariant() else {
                release(children)
                return nil
            }
            children.append(child)
        }
        guard
            let array = children.withUnsafeBufferPointer({
                g_variant_new_array(skrepka_variant_type(signature), $0.baseAddress, UInt(children.count))
            })
        else {
            release(children)
            return nil
        }
        return array
    }

    private func makeTuple(_ values: [DBusValue]) -> OpaquePointer? {
        var children: [OpaquePointer?] = []
        for value in values {
            guard let child = value.makeVariant() else {
                release(children)
                return nil
            }
            children.append(child)
        }
        guard
            let tuple = children.withUnsafeBufferPointer({
                g_variant_new_tuple($0.baseAddress, UInt(children.count))
            })
        else {
            release(children)
            return nil
        }
        return tuple
    }

    private func makeDictionary(_ values: [String: DBusValue]) -> OpaquePointer? {
        var entries: [OpaquePointer?] = []
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            guard let keyValue = g_variant_new_string(key) else {
                release(entries)
                return nil
            }
            guard let nested = value.makeVariant() else {
                g_variant_unref(keyValue)
                release(entries)
                return nil
            }
            guard let encoded = g_variant_new_variant(nested) else {
                g_variant_unref(keyValue)
                g_variant_unref(nested)
                release(entries)
                return nil
            }
            guard let entry = g_variant_new_dict_entry(keyValue, encoded) else {
                g_variant_unref(keyValue)
                g_variant_unref(encoded)
                release(entries)
                return nil
            }
            entries.append(entry)
        }
        guard
            let dictionary = entries.withUnsafeBufferPointer({
                g_variant_new_array(skrepka_variant_type("{sv}"), $0.baseAddress, UInt(entries.count))
            })
        else {
            release(entries)
            return nil
        }
        return dictionary
    }

    private func release(_ variants: [OpaquePointer?]) {
        for case let variant? in variants {
            g_variant_unref(variant)
        }
    }

    private static func parseDictionary(_ variant: OpaquePointer) -> DBusValue {
        var values: [String: DBusValue] = [:]
        for index in 0..<g_variant_n_children(variant) {
            guard let entry = g_variant_get_child_value(variant, index) else { continue }
            defer { g_variant_unref(entry) }
            guard
                let key = parseChild(entry, at: 0)?.stringValue,
                let encoded = parseChild(entry, at: 1)
            else { continue }
            if case .variant(let value) = encoded {
                values[key] = value
            } else {
                values[key] = encoded
            }
        }
        return .dictionary(values)
    }

    private static func parseChildren(_ variant: OpaquePointer) -> [DBusValue] {
        (0..<g_variant_n_children(variant)).compactMap { parseChild(variant, at: $0) }
    }

    private static func parseChild(_ variant: OpaquePointer, at index: UInt) -> DBusValue? {
        guard let child = g_variant_get_child_value(variant, index) else { return nil }
        defer { g_variant_unref(child) }
        return parse(child)
    }

    private static func arrayElement(of signature: String) -> String {
        String(signature.dropFirst())
    }
}

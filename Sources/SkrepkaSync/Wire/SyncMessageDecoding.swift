import Foundation

/// ``CBORValue`` to ``SyncMessage``, driven by the frame's type byte.
///
/// The type is read from the frame rather than from the body, so a body cannot
/// claim to be a message of some other kind than the one it was framed as.
enum SyncMessageDecoding {
    // Exhaustive over a closed message set, and deliberately left as one table
    // — see the matching note in ``SyncMessageEncoding``. Reading the two side
    // by side is how a field that one encodes and the other forgets gets
    // caught, which is worth more here than an arm count.
    //
    // Both ceilings are a function of the same thing: eleven messages, each of
    // which needs its own arm and a line per field it checks. Cutting the table
    // into halves that each fit would need a `default:` in one of them, and a
    // decoder that falls through to a default is how an unhandled message type
    // becomes a silently-accepted one.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func message(ofType type: SyncMessageType, from value: CBORValue) throws -> SyncMessage {
        let context = String(describing: type)
        let fields = try CBORFields(value, context: context)

        switch type {
        case .hello:
            return .hello(try SyncModelCoding.peerIdentity(fields, context: context))

        case .pairRequest:
            return .pairRequest(try SyncModelCoding.pairRequest(fields, context: context))

        case .pairConfirm:
            return .pairConfirm(
                deviceID: try deviceID(fields, key: "deviceID", context: context),
                accepted: try fields.boolean("accepted"),
                shortAuthenticationString: try fields.string("shortAuthenticationString")
            )

        case .indexOffer:
            return .indexOffer(
                items: try clipMetas(fields, key: "items", context: context),
                tombstones: try tombstones(fields, key: "tombstones", context: context),
                isFinal: try fields.boolean("isFinal")
            )

        case .indexRequest:
            let since = try fields.optionalInteger("since")
            return .indexRequest(since: since.map { WireTimestamp(milliseconds: $0).date })

        case .itemMeta:
            return .itemMeta(try clipMeta(fields, key: "meta", context: context))

        case .payloadRequest:
            return .payloadRequest(
                contentHash: try fields.string("contentHash"),
                key: try representationKey(fields, key: "key", context: context),
                offset: try fields.integer("offset")
            )

        case .payloadChunk:
            return .payloadChunk(try SyncModelCoding.payloadChunk(fields, context: context))

        case .tombstone:
            return .tombstone(try tombstones(fields, key: "tombstones", context: context))

        case .livePush:
            return .livePush(
                meta: try clipMeta(fields, key: "meta", context: context),
                inline: try inlineRepresentations(fields, context: context)
            )

        case .ping:
            return .ping(nonce: try fields.integer("nonce"))
        }
    }

    // MARK: - Field helpers

    private static func deviceID(
        _ fields: CBORFields,
        key: String,
        context: String
    ) throws -> SyncDeviceID {
        try SyncModelCoding.deviceID(try fields.string(key), context: "\(context).\(key)")
    }

    private static func representationKey(
        _ fields: CBORFields,
        key: String,
        context: String
    ) throws -> RepresentationKey {
        try SyncModelCoding.representationKey(try fields.required(key), context: "\(context).\(key)")
    }

    private static func clipMeta(
        _ fields: CBORFields,
        key: String,
        context: String
    ) throws -> SyncClipMeta {
        try SyncModelCoding.clipMeta(try fields.required(key), context: "\(context).\(key)")
    }

    private static func clipMetas(
        _ fields: CBORFields,
        key: String,
        context: String
    ) throws -> [SyncClipMeta] {
        try fields.array(key).enumerated()
            .map { try SyncModelCoding.clipMeta($1, context: "\(context).\(key)[\($0)]") }
    }

    private static func tombstones(
        _ fields: CBORFields,
        key: String,
        context: String
    ) throws -> [Tombstone] {
        try fields.array(key).enumerated()
            .map { try SyncModelCoding.tombstone($1, context: "\(context).\(key)[\($0)]") }
    }

    /// Rejects a repeated representation rather than letting the last one win:
    /// two sets of bytes claiming to be the same representation of the same
    /// content is a contradiction, and picking one silently is picking one
    /// arbitrarily.
    private static func inlineRepresentations(
        _ fields: CBORFields,
        context: String
    ) throws -> [RepresentationKey: Data] {
        var inline: [RepresentationKey: Data] = [:]
        for (index, element) in try fields.array("inline").enumerated() {
            let entryContext = "\(context).inline[\(index)]"
            let entry = try CBORFields(element, context: entryContext)
            let key = try SyncModelCoding.representationKey(
                try entry.required("key"),
                context: "\(entryContext).key"
            )
            guard inline.updateValue(try entry.bytes("bytes"), forKey: key) == nil else {
                throw CBORError.unexpectedShape("\(entryContext) repeats a representation key")
            }
        }
        return inline
    }
}

import Foundation

/// Hand-written CBOR coding for the model types a message carries.
///
/// Schema-driven rather than reflective. A `Codable` bridge over CBOR would
/// have to accept every shape `Codable` can express, which is a much larger
/// surface than the eleven message types this protocol has — and every extra
/// shape is one more thing a hostile body can ask the decoder to build. Written
/// out, each field's type is checked exactly once, here.
///
/// Keys are spelled in full rather than abbreviated. Metadata is a few hundred
/// bytes against a 32 MB payload ceiling, so the saving would be noise, and the
/// GNOME Shell extension of Phase 8 has to read this from JavaScript.
enum SyncModelCoding {
    // MARK: - SyncDeviceID

    static func value(_ deviceID: SyncDeviceID) -> CBORValue { .text(deviceID.hex) }

    static func deviceID(_ hex: String, context: String) throws -> SyncDeviceID {
        guard let deviceID = SyncDeviceID(hex: hex) else {
            throw CBORError.unexpectedShape("\(context) is not a device identifier")
        }
        return deviceID
    }

    // MARK: - RepresentationKey

    static func value(_ key: RepresentationKey) -> CBORValue {
        .map(fields: [
            "canonical": .text(key.canonical),
            "origin": .optional(key.origin.map(CBORValue.text)),
        ])
    }

    static func representationKey(_ value: CBORValue, context: String) throws -> RepresentationKey {
        let fields = try CBORFields(value, context: context)
        return RepresentationKey(
            canonical: try fields.string("canonical"),
            origin: try fields.optionalString("origin")
        )
    }

    // MARK: - RepresentationDescriptor

    static func value(_ descriptor: RepresentationDescriptor) -> CBORValue {
        .map(fields: [
            "key": value(descriptor.key),
            "byteCount": .integer(Int64(descriptor.byteCount)),
        ])
    }

    static func descriptor(_ value: CBORValue, context: String) throws -> RepresentationDescriptor {
        let fields = try CBORFields(value, context: context)
        return RepresentationDescriptor(
            key: try representationKey(try fields.required("key"), context: "\(context).key"),
            byteCount: try fields.count("byteCount")
        )
    }

    // MARK: - LWWRegister<Bool>

    static func value(_ register: LWWRegister<Bool>) -> CBORValue {
        .map(fields: [
            "value": .boolean(register.value),
            "timestamp": .integer(WireTimestamp(register.timestamp).milliseconds),
            "deviceID": value(register.deviceID),
        ])
    }

    static func pinRegister(_ value: CBORValue, context: String) throws -> LWWRegister<Bool> {
        let fields = try CBORFields(value, context: context)
        return LWWRegister(
            value: try fields.boolean("value"),
            timestamp: WireTimestamp(milliseconds: try fields.integer("timestamp")).date,
            deviceID: try deviceID(try fields.string("deviceID"), context: "\(context).deviceID")
        )
    }

    // MARK: - SyncClipMeta

    static func value(_ meta: SyncClipMeta) -> CBORValue {
        .map(fields: [
            "contentHash": .text(meta.contentHash),
            "kind": .text(meta.kind),
            "preview": .text(meta.preview),
            "createdAt": .integer(WireTimestamp(meta.createdAt).milliseconds),
            "isPinned": value(meta.isPinned),
            "isConcealed": .boolean(meta.isConcealed),
            "imageWidth": .optional(meta.imageWidth.map { .integer(Int64($0)) }),
            "imageHeight": .optional(meta.imageHeight.map { .integer(Int64($0)) }),
            "sourceBundleID": .optional(meta.sourceBundleID.map(CBORValue.text)),
            "originDeviceID": value(meta.originDeviceID),
            "representations": .array(meta.representations.map(value)),
        ])
    }

    static func clipMeta(_ value: CBORValue, context: String) throws -> SyncClipMeta {
        let fields = try CBORFields(value, context: context)
        let representations = try fields.array("representations").enumerated()
            .map { try descriptor($1, context: "\(context).representations[\($0)]") }
        return SyncClipMeta(
            contentHash: try fields.string("contentHash"),
            kind: try fields.string("kind"),
            preview: try fields.string("preview"),
            createdAt: WireTimestamp(milliseconds: try fields.integer("createdAt")).date,
            isPinned: try pinRegister(
                try fields.required("isPinned"),
                context: "\(context).isPinned"
            ),
            isConcealed: try fields.boolean("isConcealed"),
            imageWidth: try fields.optionalCount("imageWidth"),
            imageHeight: try fields.optionalCount("imageHeight"),
            sourceBundleID: try fields.optionalString("sourceBundleID"),
            originDeviceID: try deviceID(
                try fields.string("originDeviceID"),
                context: "\(context).originDeviceID"
            ),
            representations: representations
        )
    }

    // MARK: - Tombstone

    static func value(_ tombstone: Tombstone) -> CBORValue {
        .map(fields: [
            "contentHash": .text(tombstone.contentHash),
            "deletedAt": .integer(WireTimestamp(tombstone.deletedAt).milliseconds),
            "deviceID": value(tombstone.deviceID),
        ])
    }

    static func tombstone(_ value: CBORValue, context: String) throws -> Tombstone {
        let fields = try CBORFields(value, context: context)
        return Tombstone(
            contentHash: try fields.string("contentHash"),
            deletedAt: WireTimestamp(milliseconds: try fields.integer("deletedAt")).date,
            deviceID: try deviceID(try fields.string("deviceID"), context: "\(context).deviceID")
        )
    }

    // MARK: - Whole message bodies
    //
    // These three decode from ``CBORFields`` rather than ``CBORValue``: their
    // payload *is* the message body, which ``SyncMessageDecoding`` has already
    // proved is a map. Re-wrapping it would repeat that check and lose the
    // context string built around it.

    // MARK: - PeerIdentity

    static func value(_ identity: PeerIdentity) -> CBORValue {
        .map(fields: [
            "protocolVersion": .integer(Int64(identity.protocolVersion.rawValue)),
            "deviceID": value(identity.deviceID),
            "deviceName": .text(identity.deviceName),
            "platform": .text(identity.platform.rawValue),
            // Sorted at the wire boundary as well as in the initializer, so the
            // bytes stay canonical whatever built the value.
            "capabilities": .array(identity.capabilities.sorted().map(CBORValue.text)),
        ])
    }

    static func peerIdentity(_ fields: CBORFields, context: String) throws -> PeerIdentity {
        PeerIdentity(
            deviceID: try deviceID(try fields.string("deviceID"), context: "\(context).deviceID"),
            deviceName: try fields.string("deviceName"),
            platform: PeerPlatform(wireValue: try fields.string("platform")),
            protocolVersion: ProtocolVersion(rawValue: try fields.count("protocolVersion")),
            capabilities: try strings(fields, key: "capabilities", context: context)
        )
    }

    // MARK: - PairRequest

    static func value(_ request: PairRequest) -> CBORValue {
        .map(fields: [
            "deviceID": value(request.deviceID),
            "deviceName": .text(request.deviceName),
            "platform": .text(request.platform.rawValue),
            "certificateDER": .bytes(request.certificateDER),
            "pairedAt": .integer(WireTimestamp(request.pairedAt).milliseconds),
        ])
    }

    static func pairRequest(_ fields: CBORFields, context: String) throws -> PairRequest {
        PairRequest(
            deviceID: try deviceID(try fields.string("deviceID"), context: "\(context).deviceID"),
            deviceName: try fields.string("deviceName"),
            platform: PeerPlatform(wireValue: try fields.string("platform")),
            certificateDER: try fields.bytes("certificateDER"),
            pairedAt: WireTimestamp(milliseconds: try fields.integer("pairedAt")).date
        )
    }

    // MARK: - PayloadChunk

    static func value(_ chunk: PayloadChunk) -> CBORValue {
        .map(fields: [
            "contentHash": .text(chunk.contentHash),
            "key": value(chunk.key),
            "offset": .integer(chunk.offset),
            "bytes": .bytes(chunk.bytes),
            "isFinal": .boolean(chunk.isFinal),
        ])
    }

    static func payloadChunk(_ fields: CBORFields, context: String) throws -> PayloadChunk {
        PayloadChunk(
            contentHash: try fields.string("contentHash"),
            key: try representationKey(try fields.required("key"), context: "\(context).key"),
            offset: try fields.integer("offset"),
            bytes: try fields.bytes("bytes"),
            isFinal: try fields.boolean("isFinal")
        )
    }

    // MARK: - Shared field readers

    /// Every element of an array field as text, or a throw naming the field
    /// that holds something else.
    static func strings(_ fields: CBORFields, key: String, context: String) throws -> [String] {
        try fields.array(key).map { element in
            guard case .text(let string) = element else {
                throw CBORError.unexpectedShape("\(context).\(key) holds a non-text element")
            }
            return string
        }
    }
}

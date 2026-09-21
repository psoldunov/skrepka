import Foundation

// MARK: - Wire form

extension FileBundle {
    /// The bundle as the bytes of its representation: one CBOR array of
    /// `{name, size, bytes}` maps, in copy order.
    ///
    /// `size` is redundant with the length of `bytes` and carried anyway, so a
    /// reader can refuse a bundle whose two disagree rather than guess which
    /// one the sender meant.
    public func encoded() throws -> Data {
        guard files.count <= Self.maximumFileCount else {
            throw CBORError.unexpectedShape("file bundle holds more than \(Self.maximumFileCount) files")
        }
        return try CBOREncoder.encode(
            .array(
                files.map { file in
                    .map(fields: [
                        "name": .text(file.name),
                        "size": .integer(Int64(file.bytes.count)),
                        "bytes": .bytes(file.bytes),
                    ])
                }
            )
        )
    }

    /// Reads a bundle a peer sent. Throws on any shape other than the one
    /// ``encoded()`` writes, and on a file whose `size` is not its byte count.
    ///
    /// Extra keys in a file's map are ignored, the way every other message in
    /// this protocol ignores them, so a later revision can add one.
    public init(encoded data: Data) throws {
        guard data.count <= SyncLimits.maximumPayloadBytes else {
            throw CBORError.unexpectedShape("file bundle exceeds the payload ceiling")
        }
        guard case .array(let elements) = try CBORDecoder.decode(data) else {
            throw CBORError.unexpectedShape("file bundle is not an array")
        }
        guard elements.count <= Self.maximumFileCount else {
            throw CBORError.unexpectedShape("file bundle holds more than \(Self.maximumFileCount) files")
        }
        self.init(
            files: try elements.enumerated().map { index, element in
                try Self.file(element, context: "fileBundle[\(index)]")
            }
        )
    }

    private static func file(_ value: CBORValue, context: String) throws -> File {
        let fields = try CBORFields(value, context: context)
        let bytes = try fields.bytes("bytes")
        guard try fields.count("size") == bytes.count else {
            throw CBORError.unexpectedShape("\(context).size does not match its bytes")
        }
        return File(name: try fields.string("name"), bytes: bytes)
    }
}

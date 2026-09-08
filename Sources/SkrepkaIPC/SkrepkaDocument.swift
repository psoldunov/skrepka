import Foundation

/// A JSON document carried over the bus, or printed by `--json`.
///
/// The version is what D-Bus introspection cannot supply once the answers stop
/// being typed containers — see ``SkrepkaInterface``. Every document declares
/// the version it was written against.
///
/// It is deliberately *not* a gate. ``SkrepkaInterface``'s contract is that
/// members are added and never removed or re-signatured, so a newer document is
/// by construction still readable by an older client: `Codable` ignores the keys
/// it does not know, which is the whole reason these payloads are JSON rather
/// than typed containers. The version is diagnosis, not admission control —
/// ``SkrepkaDocumentCoding/decode(_:from:)`` reads it only once a decode has
/// actually failed, to say *why*.
public protocol SkrepkaDocument: Codable, Sendable {
    /// The document version this value was encoded at. Same number as
    /// ``SkrepkaInterface/version``, carried per document so a single member
    /// can be revised without moving the whole interface.
    var version: UInt32 { get }
}

/// One encoder and one decoder, so the daemon's bus answers and the CLI's
/// `--json` output are the same bytes.
///
/// Sorted keys and ISO-8601 dates are both about being diffable: a golden test
/// over `list --json` compares text, and an unordered dictionary or a
/// locale-dependent date makes that test flap rather than fail.
public enum SkrepkaDocumentCoding {
    /// Why a document could not be read.
    public enum Failure: Error, Sendable, CustomStringConvertible {
        /// The document did not decode *and* was written by a newer daemon,
        /// which is the likely reason. Only ever raised after a failed decode.
        case unsupportedVersion(found: UInt32, supported: UInt32)
        /// The payload was not JSON, or not this document.
        case malformed(reason: String)

        public var description: String {
            switch self {
            case .unsupportedVersion(let found, let supported):
                "the daemon speaks document version \(found); this build understands \(supported)"
            case .malformed(let reason):
                "the daemon's answer could not be read: \(reason)"
            }
        }
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Encodes a document as the JSON string that goes on the bus.
    public static func encode(_ document: some SkrepkaDocument) throws -> String {
        let data = try encoder().encode(document)
        guard let text = String(data: data, encoding: .utf8) else {
            throw Failure.malformed(reason: "the encoded document was not UTF-8")
        }
        return text
    }

    /// Decodes a document, whatever version it declares.
    ///
    /// The decode is attempted first and the version consulted only if it
    /// fails. A newer daemon's document carries keys this build has never heard
    /// of and decodes cleanly anyway, which is the point: a CLI that lags its
    /// daemon by a release keeps working, rather than refusing an answer it
    /// could have read perfectly well.
    ///
    /// When the decode genuinely fails, the version turns "keyNotFound" into
    /// something actionable — ``Failure/unsupportedVersion(found:supported:)``
    /// is now a real explanation of the failure rather than a guess ahead of it.
    public static func decode<Document: SkrepkaDocument>(
        _ type: Document.Type,
        from json: String
    ) throws -> Document {
        let data = Data(json.utf8)
        do {
            return try decoder().decode(type, from: data)
        } catch {
            // Discarded deliberately: a payload whose version cannot be read is
            // one the failure below already describes, and a second error about
            // the probe would bury the first.
            if let found = try? peekVersion(in: data), found > SkrepkaInterface.version {
                throw Failure.unsupportedVersion(found: found, supported: SkrepkaInterface.version)
            }
            throw Failure.malformed(reason: String(describing: error))
        }
    }

    private struct VersionProbe: Decodable {
        let version: UInt32
    }

    private static func peekVersion(in data: Data) throws -> UInt32 {
        try JSONDecoder().decode(VersionProbe.self, from: data).version
    }
}

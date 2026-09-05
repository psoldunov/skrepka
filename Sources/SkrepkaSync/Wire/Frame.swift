import Foundation

/// One framed message as it sat on the wire: the type byte, and the CBOR body
/// that followed it.
///
/// Separate from ``SyncMessage`` because the two failures are different. A
/// frame whose type this build does not recognise is still a well-formed frame,
/// and knowing where it ended is what lets the stream carry on to the next one.
public struct Frame: Sendable, Hashable {
    public let type: SyncMessageType
    /// The CBOR body, without the length prefix or the type byte.
    public let body: Data

    public init(type: SyncMessageType, body: Data) {
        self.type = type
        self.body = body
    }
}

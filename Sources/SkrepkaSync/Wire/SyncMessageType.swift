import Foundation

/// The one byte between a frame's length prefix and its body, per design §7.
///
/// Numbered from 1 rather than 0, so a run of zero bytes — a zeroed buffer, a
/// half-written frame — is never a valid message type.
public enum SyncMessageType: UInt8, Sendable, Hashable, Codable, CaseIterable {
    /// Protocol version, device id, platform, capabilities.
    case hello = 1
    /// First contact, design §9.
    case pairRequest = 2
    /// The other half of first contact.
    case pairConfirm = 3
    /// A list of ``SyncClipMeta``, and no payload bytes.
    case indexOffer = 4
    /// Ask for an index since a cursor.
    case indexRequest = 5
    /// One item's metadata.
    case itemMeta = 6
    /// Ask for one representation's bytes from an offset.
    case payloadRequest = 7
    /// A resumable slice of ``SyncLimits/payloadChunkBytes``.
    case payloadChunk = 8
    /// Deletion records.
    case tombstone = 9
    /// Live clipboard handoff, design §11.
    case livePush = 10
    /// Liveness.
    case ping = 11
}

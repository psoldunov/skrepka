import Foundation

/// A record that content was deleted, replicated so a re-sync does not
/// resurrect it.
///
/// Deletion writes one of these. **Eviction does not** — a 500-item cap on one
/// machine must not wipe a peer configured to keep 5000. See ``MergeEngine``.
public struct Tombstone: Sendable, Hashable, Codable {
    /// The same identity items use. A tombstone names content, not a row.
    public let contentHash: String
    /// Normalised to millisecond precision — see
    /// ``WireTimestamp/millisecondPrecision(_:)``.
    public let deletedAt: Date
    public let deviceID: SyncDeviceID

    public init(contentHash: String, deletedAt: Date, deviceID: SyncDeviceID) {
        self.contentHash = contentHash
        self.deletedAt = WireTimestamp.millisecondPrecision(deletedAt)
        self.deviceID = deviceID
    }

    /// Whether this record may be dropped, per
    /// ``SyncLimits/tombstoneRetention``.
    ///
    /// Takes the instant rather than reading a clock, so the caller stays the
    /// only thing in the model that knows what time it is.
    public func isExpired(at now: Date) -> Bool {
        now.timeIntervalSince(deletedAt) >= SyncLimits.tombstoneRetention
    }

    /// Resolves two records of the same deletion.
    ///
    /// The later `deletedAt` wins, and a tie goes to the lexicographically
    /// greater ``SyncDeviceID`` — the same rule ``LWWRegister/merged(with:)``
    /// uses, so the two never disagree about which writer won. Taking the later
    /// time rather than the earlier is the conservative direction: it holds the
    /// tombstone past its retention window for longer, and the failure mode of
    /// erring the other way is content the user deleted coming back.
    ///
    /// Callers must pass a record for the same content; the receiver's
    /// ``contentHash`` is the one kept.
    public func merged(with other: Tombstone) -> Tombstone {
        (deletedAt, deviceID) >= (other.deletedAt, other.deviceID) ? self : other
    }
}

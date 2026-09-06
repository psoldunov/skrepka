import Foundation

/// A last-writer-wins register: one value, when it was written, and which
/// device wrote it.
///
/// ``merged(with:)`` is the maximum under the total order
/// `(timestamp, deviceID, value)`, which makes it commutative, associative and
/// idempotent by construction rather than by inspection. A merge that is not
/// commutative converges to whichever side spoke last, which is precisely the
/// bug this model exists to avoid, so `LWWRegisterTests` asserts both
/// properties over generated triples including equal timestamps.
///
/// `Value` is an ``LWWValue`` for the last tie-break alone — see that protocol
/// for why it is not simply `Comparable`.
public struct LWWRegister<Value: LWWValue>: Sendable, Hashable, Codable {
    public let value: Value
    /// Normalised to millisecond precision, because that is what the wire
    /// carries. See ``WireTimestamp/millisecondPrecision(_:)``.
    public let timestamp: Date
    public let deviceID: SyncDeviceID

    public init(value: Value, timestamp: Date, deviceID: SyncDeviceID) {
        self.value = value
        self.timestamp = WireTimestamp.millisecondPrecision(timestamp)
        self.deviceID = deviceID
    }

    /// Later timestamp wins; a tie goes to the lexicographically greater
    /// ``SyncDeviceID``; a tie on both goes to the greater value.
    ///
    /// The direction of the device tie-break is arbitrary but it must be the
    /// same on both peers, which is the only property that matters — and it is
    /// the same rule ``Tombstone/merged(with:)`` uses, so the two never
    /// disagree about which writer won.
    ///
    /// **Convergent, and skew-bounded only because the transport bounds it.**
    /// ``timestamp`` is the sender's wall clock, and nothing in this type can
    /// tell a plausible one from a device an hour fast — that needs a second
    /// clock to compare against, which a value type has none of. Left to itself
    /// this ordering hands the fast machine every comparison until the skew is
    /// spent: its pin survives each later unpin from the slow one, and both
    /// peers agree on the wrong value.
    ///
    /// So the bound is applied on receipt instead, by ``InboundClock``, before
    /// any register built from a peer's bytes reaches a merge: a row whose
    /// timestamp is more than ``SyncLimits/maximumClockSkew`` ahead of the
    /// receiver's clock is dropped from the offer rather than merged. This rule
    /// stays exactly as it is — it orders what it is given, and what it is given
    /// is already bounded. See `docs/linux-sync/open-questions.md` on preferring
    /// the receiver's clock for anything stored and treating a sender's
    /// timestamp as data to order by rather than as truth.
    ///
    /// A register built locally is not checked and does not need to be: the
    /// clock it came from is the one the bound is measured against.
    public func merged(with other: Self) -> Self {
        guard timestamp == other.timestamp else { return timestamp > other.timestamp ? self : other }
        guard deviceID == other.deviceID else { return deviceID > other.deviceID ? self : other }
        return Value.lwwPrecedes(value, other.value) ? other : self
    }
}

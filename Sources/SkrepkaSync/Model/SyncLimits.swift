import Foundation

/// Every size and duration the protocol enforces, in one place, so no call site
/// invents one.
public enum SyncLimits {
    /// Largest payload that may cross the wire, in bytes.
    ///
    /// The same number as `CaptureRules.defaultMaximumItemBytes`: an item too
    /// large to capture is too large to receive, and two limits that can drift
    /// is one limit and one bug. `SkrepkaSync` cannot import `SkrepkaCore` —
    /// that target does not build on Linux — so it restates the number, and
    /// `Tests/SkrepkaCoreTests/SyncLimitsTests.swift` links both targets and
    /// fails the moment the two disagree. That test is the whole reason this
    /// duplication is acceptable.
    public static let maximumPayloadBytes = 32 * 1024 * 1024

    /// Largest CBOR body a single frame may carry.
    ///
    /// The payload ceiling plus room for the metadata wrapped around it, so a
    /// maximum-sized payload still fits in one frame with its keys and lengths.
    public static let maximumFrameBodyBytes = maximumPayloadBytes + 64 * 1024

    /// Slice size for `payloadChunk`. Resumable at this granularity.
    public static let payloadChunkBytes = 256 * 1024

    /// Above this, live push sends metadata and lets the peer fetch lazily, so
    /// a 20 MB screenshot never blocks the live channel.
    public static let livePushInlineLimit = 256 * 1024

    /// Ceiling on ``SyncClipMeta/preview``, in UTF-8 bytes.
    public static let previewByteLimit = 4 * 1024

    /// How far a `pairRequest`'s timestamp may sit from the receiver's clock,
    /// in either direction.
    ///
    /// The timestamp is half of what makes ``ShortAuthString`` replay-proof,
    /// and it only bites if staleness is enforced: without a window, a recorded
    /// exchange keeps deriving a string the user already approved. Five minutes
    /// is generous enough for two machines whose clocks were never
    /// synchronised, and short enough that an attacker gets one attempt at a
    /// 32-bit string rather than an afternoon of them.
    public static let pairingFreshnessWindow: TimeInterval = 5 * 60

    /// How long a tombstone is honoured before it may be dropped. Without
    /// tombstones a re-sync resurrects everything the user deleted; without an
    /// expiry they accumulate forever.
    public static let tombstoneRetention: TimeInterval = 60 * 60 * 24 * 90

    /// How far ahead of the receiver's own clock a peer's timestamp may reach
    /// before ``InboundClock`` refuses the row carrying it.
    ///
    /// Every ordering decision in the model — ``LWWRegister/merged(with:)``,
    /// `SyncClipMeta.createdAt`, ``Tombstone/merged(with:)`` — runs on the
    /// *sender's* wall clock. Unbounded, a peer whose clock is an hour fast
    /// wins every one of those comparisons for an hour: its pin outranks each
    /// later unpin from the honest machine, and its items sit at the top of
    /// history. Bounding the skew needs a second clock to compare against,
    /// which only the transport has, so the check lives where a message is
    /// received rather than inside a value type.
    ///
    /// Five minutes, the same number as ``pairingFreshnessWindow`` and for the
    /// same reason: generous for two machines that were never synchronised
    /// against NTP, and short enough that a wrong clock is caught the first
    /// time it matters. Only the future direction is bounded — a peer whose
    /// clock is *behind* loses ties, which is annoying and not a livelock.
    public static let maximumClockSkew: TimeInterval = 5 * 60

    /// Deepest nesting the wire decoder will follow before rejecting a body.
    ///
    /// The protocol's own messages nest four deep at most. A bound this far
    /// above that costs nothing and turns a nested-container bomb into a thrown
    /// error rather than a stack overflow, which is a crash a decoder cannot
    /// catch.
    public static let maximumWireNestingDepth = 32

    /// Most `CBORValue`s one frame body may decode into.
    ///
    /// ``ByteCursor/boundedCount(_:)`` proves a declared count is no larger
    /// than the bytes that remain, which is what stops a nine-byte body from
    /// claiming 2^40 elements. It does not bound the *product*: `0xf6` is one
    /// byte and one legitimate `CBORValue`, so an array head over 33 MB of
    /// nulls is 33.5 million enum values — 16 bytes of payload each, half a
    /// gigabyte resident and roughly twice that at the peak of the array's
    /// doubling growth, per connection, from a peer that has not paired yet.
    ///
    /// Sized from the largest message the protocol itself emits, a full
    /// `indexOffer`. One `SyncClipMeta` decodes into `29 + 9r` values for `r`
    /// representations — 101 at the eight a rich pasteboard item carries — and
    /// one ``Tombstone`` into 7. A device offering 5000 items and 5000
    /// tombstones at once therefore needs about 675,000, so 2^20 leaves better
    /// than a third of the budget spare. At the ceiling the decoder holds on
    /// the order of the frame body it came from rather than sixteen times it.
    public static let maximumWireItemCount = 1 << 20
}

import Foundation
import Testing

@testable import SkrepkaSync

/// The bound on a peer's clock, and the failure it exists to stop.
///
/// Both registers in the model order on the *sender's* wall clock, so a device
/// an hour fast writes values no honest write can outrank until that hour is
/// spent. `MergeEngine` cannot see it — it is pure, and its `now` is one
/// sender-independent instant rather than a second opinion — so the check runs
/// on receipt, in ``InboundClock``, and these tests assert it at the seam where
/// an offer meets a merge.
@Suite("Clock skew")
struct ClockSkewTests {
    /// The receiver's clock throughout. Every "ahead" below is measured from it.
    private let now = SyncFixtures.epoch

    private func pinRegisters(_ plan: [MergeAction]) -> [LWWRegister<Bool>] {
        plan.compactMap { action in
            guard case .applyPin(_, let register) = action else { return nil }
            return register
        }
    }

    /// The exact failure: the Linux box's clock is an hour fast, so it pinned
    /// item X at a stamp of `now + 3600`. The user then unpins X on the Mac at
    /// `now`. Unfiltered, the pin wins and the item re-pins itself — and does so
    /// again after every later unpin, for the whole hour of skew.
    @Test("An hour-ahead pin does not beat an unpin made now")
    func refusesAnOfferStampedAnHourAhead() {
        let local = SyncFixtures.meta(
            "aa",
            pinned: SyncFixtures.pin(false, at: 0, by: SyncFixtures.deviceA)
        )
        let remote = SyncFixtures.meta(
            "aa",
            pinned: SyncFixtures.pin(true, at: 3600, by: SyncFixtures.deviceB)
        )

        let unfiltered = MergeEngine.plan(
            MergeInput(localItems: [local], remoteItems: [remote], now: now)
        )
        #expect(pinRegisters(unfiltered).map(\.value) == [true])

        let filtered = MergeEngine.plan(
            MergeInput(
                localItems: [local],
                remoteItems: InboundClock.plausible([remote], receivedAt: now),
                now: now
            )
        )
        #expect(pinRegisters(filtered).isEmpty)
    }

    /// `createdAt` carries the same defect: a fast peer's items sit permanently
    /// at the top of history, because ``SyncClipMeta/combining(_:)`` takes the
    /// maximum of the two.
    @Test("An hour-ahead createdAt does not bump a local item")
    func refusesAFutureCreatedAt() {
        let remote = SyncFixtures.meta("bb", createdAt: 3600)
        #expect(InboundClock.plausible([remote], receivedAt: now).isEmpty)
    }

    /// One item is judged whole. A row whose `createdAt` is honest and whose pin
    /// register is not would otherwise merge half a lie.
    @Test("A skewed pin register refuses the item even when createdAt is honest")
    func refusesAnItemWhosePinAloneIsSkewed() {
        let remote = SyncFixtures.meta(
            "cc",
            createdAt: -60,
            pinned: SyncFixtures.pin(true, at: 3600, by: SyncFixtures.deviceB)
        )
        #expect(!InboundClock.isPlausible(remote, receivedAt: now))
    }

    /// A tombstone stamped in the future would outlive its retention window by
    /// the length of the skew and beat every honest record of the same deletion.
    @Test("An hour-ahead tombstone is refused and an ordinary one is kept")
    func refusesAFutureTombstone() {
        let skewed = SyncFixtures.tombstone("dd", deletedAt: 3600)
        let honest = SyncFixtures.tombstone("ee", deletedAt: -5)

        #expect(InboundClock.plausible([skewed, honest], receivedAt: now) == [honest])
    }

    /// The window has to be wide enough that two machines which were never
    /// synchronised against NTP still sync, or the bound costs more than the
    /// skew did.
    @Test("Ordinary drift inside the window is accepted, and the past always is")
    func acceptsDriftInsideTheWindow() {
        #expect(InboundClock.isPlausible(SyncFixtures.time(60), receivedAt: now))
        #expect(InboundClock.isPlausible(SyncFixtures.time(-60 * 60 * 24), receivedAt: now))
        #expect(InboundClock.isPlausible(SyncFixtures.meta("ff", createdAt: -1), receivedAt: now))
    }

    /// The edge, at wire precision: exactly at the window is inside it, and the
    /// next millisecond a peer can express is not.
    @Test("The window is closed at its far end and open past it")
    func boundsTheWindowExactly() {
        let edge = SyncLimits.maximumClockSkew
        #expect(InboundClock.isPlausible(SyncFixtures.time(edge), receivedAt: now))
        #expect(!InboundClock.isPlausible(SyncFixtures.time(edge + 0.001), receivedAt: now))
    }
}

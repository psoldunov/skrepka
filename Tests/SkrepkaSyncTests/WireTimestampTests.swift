import Foundation
import Testing

@testable import SkrepkaSync

/// Milliseconds since the Unix epoch, and the two ways converting to them can
/// go wrong.
@Suite("Wire timestamp")
struct WireTimestampTests {
    /// Converting is idempotent: normalising an already-normalised instant
    /// changes nothing. That is the property the model leans on — a `createdAt`
    /// that shifted a little on every hop would never let two peers agree.
    @Test("Normalising an instant twice is the same as normalising it once")
    func normalisationIsIdempotent() {
        for offset in [-86_400.0, -1.5, -0.001, 0, 0.000_4, 0.001, 1.5, 86_400.0] {
            let stamp = WireTimestamp(SyncFixtures.epoch.addingTimeInterval(offset))
            #expect(WireTimestamp(stamp.date) == stamp)
            let normalised = WireTimestamp.millisecondPrecision(stamp.date)
            #expect(WireTimestamp.millisecondPrecision(normalised) == normalised)
        }
    }

    @Test("A whole-second instant survives the round trip exactly")
    func roundTripsWholeSeconds() {
        for offset in [-86_400.0, -1, 0, 1, 86_400.0] {
            let date = SyncFixtures.epoch.addingTimeInterval(offset)
            #expect(WireTimestamp(date).date == date)
        }
    }

    /// The wire carries whole milliseconds, so anything finer is rounded rather
    /// than carried. Model types normalise on construction for exactly this
    /// reason: without it a sub-millisecond difference survives every merge and
    /// two peers never quite agree on `createdAt`.
    @Test("Sub-millisecond precision rounds rather than drifting")
    func roundsToTheNearestMillisecond() {
        let epochMilliseconds = WireTimestamp(SyncFixtures.epoch).milliseconds
        #expect(
            WireTimestamp(SyncFixtures.epoch.addingTimeInterval(0.000_4)).milliseconds
                == epochMilliseconds
        )
        #expect(
            WireTimestamp(SyncFixtures.epoch.addingTimeInterval(0.000_6)).milliseconds
                == epochMilliseconds + 1
        )
        #expect(
            WireTimestamp.millisecondPrecision(SyncFixtures.epoch.addingTimeInterval(0.000_4))
                == SyncFixtures.epoch
        )
    }

    /// A `Date` outside the representable millisecond range saturates. It
    /// matters because a trap here would be a crash on a value that can arrive
    /// from storage or from a peer, and the comparison has to stay total.
    @Test("An unrepresentable instant saturates instead of trapping")
    func saturatesRatherThanTrapping() {
        #expect(WireTimestamp(Date(timeIntervalSince1970: 1e300)).milliseconds == Int64.max)
        #expect(WireTimestamp(Date(timeIntervalSince1970: -1e300)).milliseconds == Int64.min)
        #expect(WireTimestamp(Date(timeIntervalSince1970: .infinity)).milliseconds == Int64.max)
        #expect(WireTimestamp(Date(timeIntervalSince1970: -.infinity)).milliseconds == Int64.min)
        // NaN has no sign to saturate towards; it must still not trap.
        #expect(WireTimestamp(Date(timeIntervalSince1970: .nan)).milliseconds == Int64.max)

        // `Date.distantFuture` and `Date.distantPast` are well inside the
        // range, and are not saturated — the guard is for values that are not.
        #expect(WireTimestamp(Date.distantFuture).milliseconds < Int64.max)
        #expect(WireTimestamp(Date.distantPast).milliseconds > Int64.min)
    }

    @Test("Timestamps order by their millisecond count")
    func ordersByMilliseconds() {
        #expect(WireTimestamp(milliseconds: -1) < WireTimestamp(milliseconds: 0))
        #expect(WireTimestamp(milliseconds: 0) < WireTimestamp(milliseconds: 1))
        #expect(!(WireTimestamp(milliseconds: 1) < WireTimestamp(milliseconds: 1)))
    }
}

import Foundation
import Testing

@testable import SkrepkaSync

/// The register's two algebraic properties, asserted rather than asserted-about.
@Suite("LWW register")
struct LWWRegisterTests {
    /// Every combination of value, timestamp and device over a small space —
    /// including equal timestamps, which is where a merge stops being
    /// commutative if the tie-break is wrong.
    private static let registers: [LWWRegister<Bool>] = {
        let devices = [SyncFixtures.deviceA, SyncFixtures.deviceB]
        return [false, true].flatMap { value in
            [0.0, 0.0, 1.0, 2.0].flatMap { seconds in
                devices.map { LWWRegister(value: value, timestamp: SyncFixtures.time(seconds), deviceID: $0) }
            }
        }
    }()

    @Test("Merging is commutative and associative over every triple")
    func mergeIsCommutativeAndAssociative() {
        for first in Self.registers {
            for second in Self.registers {
                #expect(first.merged(with: second) == second.merged(with: first))
                #expect(first.merged(with: first) == first)

                for third in Self.registers {
                    let left = first.merged(with: second).merged(with: third)
                    let right = first.merged(with: second.merged(with: third))
                    #expect(left == right)
                }
            }
        }
    }

    /// The tie-break has to be deterministic *and* the same on both peers, or
    /// two devices settle on different values and never notice.
    @Test("An equal timestamp is broken by device identifier, the same way on both peers")
    func deviceIDBreaksTies() {
        #expect(SyncFixtures.deviceA < SyncFixtures.deviceB)
        let fromA = LWWRegister(value: false, timestamp: SyncFixtures.epoch, deviceID: SyncFixtures.deviceA)
        let fromB = LWWRegister(value: true, timestamp: SyncFixtures.epoch, deviceID: SyncFixtures.deviceB)

        #expect(fromA.merged(with: fromB) == fromB)
        #expect(fromB.merged(with: fromA) == fromB)
    }

    @Test("A later timestamp wins regardless of device or value")
    func laterTimestampWins() {
        let early = LWWRegister(value: true, timestamp: SyncFixtures.time(1), deviceID: SyncFixtures.deviceB)
        let late = LWWRegister(value: false, timestamp: SyncFixtures.time(2), deviceID: SyncFixtures.deviceA)

        #expect(early.merged(with: late) == late)
        #expect(late.merged(with: early) == late)
    }

    /// The last tie-break, reached only when timestamp and device both match.
    /// It is why `Value` is an ``LWWValue`` rather than merely `Hashable`.
    @Test("An identical timestamp and device is broken by the value")
    func valueBreaksTheLastTie() {
        let unpinned = LWWRegister(
            value: false, timestamp: SyncFixtures.epoch, deviceID: SyncFixtures.deviceA)
        let pinned = LWWRegister(value: true, timestamp: SyncFixtures.epoch, deviceID: SyncFixtures.deviceA)

        #expect(unpinned.merged(with: pinned) == pinned)
        #expect(pinned.merged(with: unpinned) == pinned)
    }

    /// Why ``InboundClock`` has to exist, asserted here rather than described.
    ///
    /// The rule orders on the sender's wall clock and has no way to tell a
    /// plausible stamp from a wrong one: a device an hour fast outranks every
    /// honest write until that hour is spent, and both peers agree on the wrong
    /// value. Nothing in this type can fix that — bounding the skew needs a
    /// second clock, which only the transport holds — so the bound is applied on
    /// receipt, and `ClockSkewTests` is where it is asserted end to end.
    @Test("A future timestamp wins, which is what the transport has to bound")
    func aFutureTimestampWinsUntilTheTransportBoundsIt() {
        let honestUnpin = LWWRegister(
            value: false, timestamp: SyncFixtures.epoch, deviceID: SyncFixtures.deviceA)
        let skewedPin = LWWRegister(
            value: true, timestamp: SyncFixtures.time(60 * 60), deviceID: SyncFixtures.deviceB)

        #expect(honestUnpin.merged(with: skewedPin) == skewedPin)
        #expect(InboundClock.isPlausible(honestUnpin.timestamp, receivedAt: SyncFixtures.epoch))
        #expect(!InboundClock.isPlausible(skewedPin.timestamp, receivedAt: SyncFixtures.epoch))
    }

    /// The model normalises to what the wire carries, so a register built from
    /// a sub-millisecond `Date` compares equal to the one that crosses.
    @Test("Timestamps are held at wire precision")
    func normalisesTimestampsToMilliseconds() {
        let ragged = SyncFixtures.epoch.addingTimeInterval(0.000_4)
        let register = LWWRegister(value: true, timestamp: ragged, deviceID: SyncFixtures.deviceA)
        #expect(register.timestamp == SyncFixtures.epoch)
    }
}

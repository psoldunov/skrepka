import Foundation
import Testing

@testable import SkrepkaSync

/// The one decision that separates "macOS has not let us on yet" from "that went
/// wrong".
///
/// Worth a suite of its own because getting it backwards is invisible in both
/// directions. Retry the permission and the app asks a refused question every few
/// seconds while the system alert is still on screen; do not retry the rest and a
/// publish that fails once never happens again, because the browse reaches
/// `.ready` exactly once on a network that does not change.
@Suite("Publish retry policy")
struct PublishRetryPolicyTests {
    private struct Transient: Error {}

    @Test("A refused privilege is waited out rather than retried")
    func deniedAccessWaits() {
        #expect(
            PublishRetryPolicy.recovery(from: DiscoveryError.localNetworkDenied, afterAttempts: 0)
                == .waitForAccess
        )
    }

    /// However many times it has happened. There is no attempt count at which
    /// hammering a refused privilege becomes the right move, and the browse is
    /// still the thing that will say when it changes.
    @Test("A refused privilege is still waited out after any number of attempts")
    func deniedAccessNeverBecomesARetry() {
        for attempts in 0...(PublishRetryPolicy.delays.count + 2) {
            #expect(
                PublishRetryPolicy.recovery(
                    from: DiscoveryError.localNetworkDenied,
                    afterAttempts: attempts
                ) == .waitForAccess
            )
        }
    }

    @Test("Any other discovery failure is retried on the schedule")
    func otherDiscoveryFailuresRetry() {
        let error = DiscoveryError.advertisingFailed(reason: "the service name is already taken")
        for (attempts, delay) in PublishRetryPolicy.delays.enumerated() {
            #expect(
                PublishRetryPolicy.recovery(from: error, afterAttempts: attempts)
                    == .retry(after: delay)
            )
        }
    }

    /// Not only `DiscoveryError`: what reaches the coordinator's catch is
    /// whatever `updateAdvertisement` threw, and anything that is not the
    /// privilege is a fault worth another go.
    @Test("An error from outside discovery is retried too")
    func foreignErrorsRetry() {
        #expect(
            PublishRetryPolicy.recovery(from: Transient(), afterAttempts: 0)
                == .retry(after: PublishRetryPolicy.delays[0])
        )
    }

    @Test("The schedule runs out rather than going round again")
    func theScheduleIsBounded() {
        let error = DiscoveryError.advertisingLost(reason: "the registration was torn down")
        #expect(
            PublishRetryPolicy.recovery(from: error, afterAttempts: PublishRetryPolicy.delays.count)
                == .giveUp
        )
        #expect(
            PublishRetryPolicy.recovery(from: error, afterAttempts: 99) == .giveUp
        )
    }

    /// A negative count is nobody's plan, but the answer to one must not be an
    /// index out of range on the main actor.
    @Test("A nonsensical attempt count gives up rather than trapping")
    func negativeAttemptsGiveUp() {
        #expect(
            PublishRetryPolicy.recovery(from: Transient(), afterAttempts: -1) == .giveUp
        )
    }
}

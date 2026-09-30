import Testing

@testable import SkrepkaLinuxUI

@Suite("App: checking the daemon again after a failed check")
struct DaemonRecheckTests {
    @Test("the first retry comes within seconds, for a daemon still coming up")
    func theFirstRetryIsQuick() {
        #expect(DaemonRecheck.delay(afterFailures: 1) == 2)
    }

    @Test("retries slow down, then settle at every half minute")
    func retriesBackOffAndSettle() {
        let delays = (1...6).map { DaemonRecheck.delay(afterFailures: $0) }
        #expect(delays == [2, 5, 10, 30, 30, 30])
    }

    @Test("a count below one is read as the first failure")
    func aCountBelowOneIsTheFirst() {
        #expect(DaemonRecheck.delay(afterFailures: 0) == 2)
        #expect(DaemonRecheck.delay(afterFailures: -3) == 2)
    }
}

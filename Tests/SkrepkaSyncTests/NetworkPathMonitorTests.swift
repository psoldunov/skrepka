#if canImport(Network)

    import Foundation
    import Testing

    @testable import SkrepkaSync

    /// macOS only, because this is the one piece of Network framework the plan
    /// keeps — see [D-9].
    @Suite("Network path monitor")
    struct NetworkPathMonitorTests {
        /// The measured behaviour ``NetworkPathMonitor`` is built on: iterating
        /// an `NWPathMonitor` starts it, so a first element arrives with no
        /// network change at all and a caller never has to read `currentPath`
        /// — which reads `.unsatisfied` before a start, on a machine with
        /// working Wi-Fi.
        ///
        /// Asserts only that *an* element arrives. Whether it is `true` depends
        /// on the machine running the tests, and a test that demanded a network
        /// would fail in a sandbox for the wrong reason.
        @Test("A first reading arrives without anything having changed", .timeLimit(.minutes(1)))
        func deliversAnInitialReading() async throws {
            var iterator = NetworkPathMonitor.reachability().makeAsyncIterator()
            let reachable = await iterator.next()
            #expect(reachable != nil)
        }
    }

#endif

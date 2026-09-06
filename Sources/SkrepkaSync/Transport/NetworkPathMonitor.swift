#if canImport(Network)

    import Foundation
    import Network

    /// Reachability changes, on macOS, over the one NIO transport.
    ///
    /// This is the half of Network framework [D-9] keeps. The genuine gap
    /// between the two stacks was never TLS — it is that Network framework
    /// notices sleep, wake, Wi-Fi changes and VPN transitions and NIO does not,
    /// and a laptop doing LAN sync hits all four daily. Reconnect *policy* is
    /// Phase 3's; this is the signal it will read.
    ///
    /// **Never reads `currentPath` before the monitor has started.** A fresh
    /// `NWPathMonitor` reports `.unsatisfied` until then — measured, twice, on
    /// a machine with working Wi-Fi, and recorded in `open-questions.md#oq-7`.
    /// Seeding a reconnect loop from that value tells it the network is down on
    /// a perfectly connected Mac.
    public enum NetworkPathMonitor {
        /// Whether a LAN peer could be reached, as it changes.
        ///
        /// The first element arrives within milliseconds of subscribing with no
        /// network change at all, so a caller does not have to seed itself.
        ///
        /// Iterating `NWPathMonitor` starts it; `start(queue:)` is neither
        /// needed nor called. The SDK's own `.swiftinterface` declares the
        /// `AsyncSequence` conformance but does not say whether iteration
        /// starts the monitor, so that was settled by running it: a fresh
        /// monitor, iterated and never started, delivered `.satisfied` inside
        /// three seconds.
        public static func reachability() -> AsyncStream<Bool> {
            AsyncStream { continuation in
                let monitor = NWPathMonitor()
                let task = Task {
                    for await path in monitor {
                        continuation.yield(path.status == .satisfied)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in
                    task.cancel()
                    monitor.cancel()
                }
            }
        }
    }

#endif

#if canImport(Network) && canImport(dnssd)

    import Foundation
    import Network

    extension BonjourDiscovery {
        /// **Synchronous on purpose, and that is load-bearing rather than
        /// incidental.**
        ///
        /// ``beginBrowse()`` starts the `NWBrowser` *before* this subscribes, and
        /// on a Mac that already has Local Network access `.ready` follows within
        /// milliseconds. ``EventFanout/deliver(_:)`` yields only to the
        /// subscribers registered at the instant it runs and buffers nothing for
        /// a subscriber that has not arrived yet, so a `.ready` delivered before
        /// the `subscribe` below would simply be gone.
        ///
        /// What stops that is that this function never suspends. It is an actor
        /// method with no `await` in it, so `beginBrowse()` and `subscribe` are
        /// one indivisible step as far as the actor is concerned, and the pump
        /// task's `await deliver(event)` cannot be admitted until the subscriber
        /// exists.
        ///
        /// Making it `async`, or adding an `await` between those two lines,
        /// breaks the whole Local Network permission gate and breaks it silently:
        /// `SyncCoordinator.performPublish()` hangs off `.ready`, `.ready` on a
        /// settled network arrives exactly once, and no test here would fail —
        /// the app would just never publish itself. If this has to suspend one
        /// day, subscribe first and start the browser afterwards.
        public func startBrowsing() throws -> AsyncStream<DiscoveryEvent> {
            if browser == nil { beginBrowse() }
            return browseFanout.subscribe { [weak self] token in
                Task { await self?.dropBrowseSubscriber(token) }
            }.stream
        }

        /// Starts the one `NWBrowser` every subscriber reads from.
        private func beginBrowse() {
            let (source, continuation) = AsyncStream<DiscoveryEvent>.makeStream()
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: ServiceDescriptor.serviceType, domain: nil),
                using: .tcp
            )
            browser.stateUpdateHandler = { state in
                BonjourDiscovery.report(state, to: continuation)
            }
            browser.browseResultsChangedHandler = { _, changes in
                for change in changes {
                    guard let event = BonjourDiscovery.event(for: change) else { continue }
                    continuation.yield(event)
                }
            }
            browser.start(queue: queue)
            self.browser = browser
            browseSource = continuation
            Task { [weak self] in
                for await event in source { await self?.deliver(event) }
                // The source ends only where ``report(_:to:)`` finished it,
                // which is a terminal browser state. browser.h:68-72 says a
                // failed browser cannot be restarted and must be cancelled and
                // replaced, so the browse is torn down here and a later
                // ``startBrowsing()`` builds a fresh one.
                await self?.stopBrowsing()
            }
        }

        /// Turns one browser state change into what a caller can act on.
        ///
        /// `.failed` and `.waiting` used to share a `case`, and the SDK defines
        /// them as opposites. browser.h:68-72 — `.failed` "has irrecoverably
        /// failed. You should not try to call nw_browser_start() on the browser
        /// to restart it. Instead, cancel the browser and create a new browser
        /// object" — so it ends the stream. browser.h:80-85 — `.waiting` "is
        /// waiting for connectivity", and a browser "can move from the ready
        /// state into the waiting state" and back — so it does not, and it is
        /// not reported as a failure. Where Local Network access has not been
        /// granted the browser sits in `.waiting`, which under the old shape
        /// showed the user an error for a permission prompt they had not
        /// answered yet.
        private static func report(
            _ state: NWBrowser.State,
            to continuation: AsyncStream<DiscoveryEvent>.Continuation
        ) {
            switch state {
            case .ready:
                continuation.yield(.ready)
            case .waiting(let error):
                continuation.yield(.stalled(stall(from: error)))
            case .failed(let error):
                continuation.yield(.failed(.browsingFailed(reason: "\(error)")))
                continuation.finish()
            case .cancelled:
                continuation.finish()
            default:
                break
            }
        }

        /// Tells the two reasons a browse waits apart.
        ///
        /// `.waiting` covers both "there is no network yet" and "macOS has not
        /// granted this app the local network", and only the second one has an
        /// answer the user can act on. TN3179 (*Understanding local network
        /// privacy*), under "Check for local network access", names exactly this
        /// check: a browse without access waits with `kDNSServiceErr_PolicyDenied`
        /// (-65570), so the `NWError.dns` payload is the signal.
        ///
        /// It arrives while the system's own alert is still on screen as well as
        /// after the user has refused — TN3179 says the operation is denied
        /// immediately either way — so a caller must treat it as "not yet"
        /// rather than "never". `NWBrowser` returns to `.ready` by itself once
        /// access is granted, which is what makes waiting for that the whole
        /// permission gate.
        private static func stall(from error: NWError) -> DiscoveryError {
            if case .dns(let code) = error, code == BonjourDiscovery.Status.policyDenied {
                return .localNetworkDenied
            }
            return .browsingStalled(reason: "\(error)")
        }

        /// Fans one event out to every subscriber, on the actor, in order.
        func deliver(_ event: DiscoveryEvent) {
            browseFanout.deliver(event)
        }

        func dropBrowseSubscriber(_ token: EventFanout<DiscoveryEvent>.Token) {
            browseFanout.remove(token)
        }

        public func stopBrowsing() {
            browser?.cancel()
            browser = nil
            browseSource?.finish()
            browseSource = nil
            browseFanout.finish()
        }
    }

#endif

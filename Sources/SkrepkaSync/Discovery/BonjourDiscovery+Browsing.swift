#if canImport(Network) && canImport(dnssd)

    import Foundation
    import Network

    extension BonjourDiscovery {
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
                continuation.yield(.stalled(.browsingStalled(reason: "\(error)")))
            case .failed(let error):
                continuation.yield(.failed(.browsingFailed(reason: "\(error)")))
                continuation.finish()
            case .cancelled:
                continuation.finish()
            default:
                break
            }
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

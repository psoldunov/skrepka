#if canImport(Network) && canImport(dnssd)

    import Foundation
    import dnssd

    extension BonjourDiscovery {
        public func resolve(_ peer: DiscoveredPeer, timeout: Duration) async throws -> ResolvedPeer {
            let sink = DNSServiceReplySink<ResolutionReply>()
            let context = sink.retainedContext()
            var reference: DNSServiceRef?
            let status = DNSServiceResolve(
                &reference,
                0,
                // `nil` means "any interface", which dns_sd spells as zero.
                peer.interfaceIndex ?? 0,
                peer.instanceName,
                peer.serviceType,
                peer.domain,
                BonjourDiscovery.resolutionReply,
                context
            )
            guard status == BonjourDiscovery.Status.noError, let reference else {
                DNSServiceReplySink<ResolutionReply>.release(context: context)
                throw DiscoveryError.resolutionFailed(
                    peer: peer.instanceName,
                    reason: BonjourDiscovery.message(for: status)
                )
            }
            // dns_sd.h:3090-3094. Unchecked, a query whose dispatch source was
            // never created burns the caller's whole timeout and then reports
            // it as the peer failing to answer — on every peer, every attempt.
            let scheduled = DNSServiceSetDispatchQueue(reference, queue)
            guard scheduled == BonjourDiscovery.Status.noError else {
                sink.continuation.finish()
                queue.sync { DNSServiceRefDeallocate(reference) }
                DNSServiceReplySink<ResolutionReply>.release(context: context)
                throw DiscoveryError.resolutionFailed(
                    peer: peer.instanceName,
                    reason: BonjourDiscovery.message(for: scheduled)
                )
            }
            defer {
                sink.continuation.finish()
                queue.sync { DNSServiceRefDeallocate(reference) }
                DNSServiceReplySink<ResolutionReply>.release(context: context)
            }
            return try resolved(peer, from: await sink.first(timeout: timeout))
        }

        private func resolved(
            _ peer: DiscoveredPeer,
            from outcome: DNSServiceReplySink<ResolutionReply>.Outcome
        ) throws -> ResolvedPeer {
            switch outcome {
            case .reply(let reply) where reply.errorCode == BonjourDiscovery.Status.noError:
                do {
                    return ResolvedPeer(
                        peer: peer,
                        host: reply.hostTarget,
                        port: reply.port,
                        advertisement: try PeerAdvertisement(dnsSDWireFormat: reply.txtRecord)
                    )
                } catch let error as AdvertisementError {
                    throw DiscoveryError.malformedAdvertisement(
                        peer: peer.instanceName, error: error)
                }
            case .reply(let reply):
                throw DiscoveryError.resolutionFailed(
                    peer: peer.instanceName,
                    reason: BonjourDiscovery.message(for: reply.errorCode)
                )
            case .ended:
                throw DiscoveryError.resolutionFailed(
                    peer: peer.instanceName, reason: "the query was torn down")
            case .timedOut:
                throw DiscoveryError.resolutionTimedOut(peer: peer.instanceName)
            }
        }
    }

#endif

#if canImport(Network) && canImport(dnssd)

    import Foundation
    import dnssd

    extension BonjourDiscovery {
        public func startAdvertising(_ descriptor: ServiceDescriptor) async throws {
            guard registrationRef == nil else { throw DiscoveryError.alreadyAdvertising }
            let txtRecord = try descriptor.txtRecord().dnsSDWireFormat

            let sink = DNSServiceReplySink<RegistrationReply>()
            let context = sink.retainedContext()
            let registered = BonjourDiscovery.register(
                descriptor, txtRecord: txtRecord, context: context)
            guard registered.status == BonjourDiscovery.Status.noError,
                let reference = registered.reference
            else {
                DNSServiceReplySink<RegistrationReply>.release(context: context)
                throw DiscoveryError.advertisingFailed(
                    reason: BonjourDiscovery.message(for: registered.status))
            }

            // dns_sd.h:3090-3094: this returns `kDNSServiceErr_NoMemory` when
            // it cannot create the dispatch source and `kDNSServiceErr_BadParam`
            // for a bad service or queue. Dropping it buys a registration whose
            // callback is never scheduled, which looks from here exactly like a
            // responder that went silent — the caller waits out
            // ``registrationTimeout`` and is then told the responder did not
            // answer, about a responder that is working fine.
            let scheduled = DNSServiceSetDispatchQueue(reference, queue)
            guard scheduled == BonjourDiscovery.Status.noError else {
                queue.sync { DNSServiceRefDeallocate(reference) }
                DNSServiceReplySink<RegistrationReply>.release(context: context)
                throw DiscoveryError.advertisingFailed(
                    reason: BonjourDiscovery.message(for: scheduled))
            }
            registrationRef = reference
            registrationSink = sink
            registrationContext = context

            try await confirmRegistration(from: sink, port: descriptor.port)
            watchRegistration(sink, port: descriptor.port)
        }

        /// The `DNSServiceRegister` call itself, lifted out so
        /// ``startAdvertising(_:)`` reads as the sequence of checks it is.
        private static func register(
            _ descriptor: ServiceDescriptor,
            txtRecord: Data,
            context: UnsafeMutableRawPointer
        ) -> (status: DNSServiceErrorType, reference: DNSServiceRef?) {
            var reference: DNSServiceRef?
            let status = txtRecord.withUnsafeBytes { buffer -> DNSServiceErrorType in
                guard let length = UInt16(exactly: buffer.count) else {
                    return BonjourDiscovery.Status.badParam
                }
                return DNSServiceRegister(
                    &reference,
                    // No flags. `kDNSServiceFlagsNoAutoRename` is deliberately
                    // absent — see ``ServiceRegistration`` for why a renamed
                    // instance beats a refused one.
                    0,
                    // Every interface.
                    0,
                    descriptor.displayName.isEmpty ? nil : descriptor.displayName,
                    ServiceDescriptor.serviceType,
                    nil,  // The default registration domain, which is local.
                    nil,  // This host.
                    descriptor.port.bigEndian,
                    length,
                    buffer.baseAddress,
                    BonjourDiscovery.registrationReply,
                    context
                )
            }
            return (status, reference)
        }

        /// Waits for the responder's answer, which is also the only place the
        /// granted instance name appears.
        private func confirmRegistration(
            from sink: DNSServiceReplySink<RegistrationReply>,
            port: UInt16
        ) async throws {
            switch await sink.first(timeout: Self.registrationTimeout) {
            case .reply(let reply) where reply.errorCode == BonjourDiscovery.Status.noError:
                registration = ServiceRegistration(
                    name: reply.name,
                    serviceType: reply.serviceType,
                    domain: reply.domain,
                    port: port
                )
            case .reply(let reply):
                stopAdvertising()
                throw DiscoveryError.advertisingFailed(
                    reason: BonjourDiscovery.message(for: reply.errorCode))
            case .ended:
                stopAdvertising()
                throw DiscoveryError.advertisingLost(reason: "the registration was torn down")
            case .timedOut:
                stopAdvertising()
                throw DiscoveryError.advertisingFailed(
                    reason: "mDNSResponder did not confirm the registration")
            }
        }

        /// Keeps reading the registration's callbacks after the first one.
        ///
        /// `DNSServiceRegisterReply` fires more than once by contract.
        /// dns_sd.h:1275-1284: a successfully registered name that "later
        /// suffers a name conflict or similar problem and has to be
        /// deregistered" is reported by a second callback with
        /// `kDNSServiceFlagsAdd` *not* set, and dns_sd.h:3103-3106 adds that a
        /// responder which is killed or crashes delivers
        /// `kDNSServiceErr_ServiceNotRunning` the same way and that the
        /// application must then call `DNSServiceRefDeallocate`. Without this,
        /// that callback lands in a buffered stream nobody reads: the Mac is
        /// off the network, ``registration`` still says otherwise, and the ref
        /// the header says to free stays open.
        private func watchRegistration(
            _ sink: DNSServiceReplySink<RegistrationReply>,
            port: UInt16
        ) {
            // Not retained: the loop ends when ``stopAdvertising()`` finishes
            // the sink, which is the only way this registration can end.
            Task { [weak self] in await self?.followRegistration(sink, port: port) }
        }

        private func followRegistration(
            _ sink: DNSServiceReplySink<RegistrationReply>,
            port: UInt16
        ) async {
            for await reply in sink.replies {
                guard reply.errorCode == BonjourDiscovery.Status.noError, reply.isAdd else {
                    advertisementWasLost(reply)
                    return
                }
                // dns_sd.h:1276-1279: more than one success callback is normal
                // — wide-area DNS-SD registers the same service in a second
                // domain — and each one carries the name that was granted
                // there, so the latest answer replaces the earlier one.
                registration = ServiceRegistration(
                    name: reply.name,
                    serviceType: reply.serviceType,
                    domain: reply.domain,
                    port: port
                )
            }
        }

        /// The advertisement was confirmed and is now gone.
        private func advertisementWasLost(_ reply: RegistrationReply) {
            let reason =
                reply.errorCode == BonjourDiscovery.Status.noError
                ? "the responder deregistered it"
                : BonjourDiscovery.message(for: reply.errorCode)
            // Delivered before the teardown, because ``stopAdvertising()``
            // finishes the very streams this has to reach.
            advertisementFanout.deliver(.advertisingLost(reason: reason))
            // dns_sd.h:3105-3106 requires the ref be deallocated on such an
            // error. `stopAdvertising()` is that call plus the rest of it.
            stopAdvertising()
        }

        public func advertisementFailures() -> AsyncStream<DiscoveryError> {
            advertisementFanout.subscribe { [weak self] token in
                Task { await self?.dropAdvertisementSubscriber(token) }
            }.stream
        }

        func dropAdvertisementSubscriber(_ token: EventFanout<DiscoveryError>.Token) {
            advertisementFanout.remove(token)
        }

        public func stopAdvertising() {
            registration = nil
            registrationSink?.continuation.finish()
            registrationSink = nil
            if let reference = registrationRef {
                registrationRef = nil
                // `sync`, not `async`: dns_sd.h requires this call on `queue`,
                // and the reference has to be gone before the sink's last
                // reference is released. Nothing on `queue` blocks on this
                // actor, so there is nothing here to deadlock against.
                queue.sync { DNSServiceRefDeallocate(reference) }
            }
            if let context = registrationContext {
                registrationContext = nil
                DNSServiceReplySink<RegistrationReply>.release(context: context)
            }
            advertisementFanout.finish()
        }
    }

#endif

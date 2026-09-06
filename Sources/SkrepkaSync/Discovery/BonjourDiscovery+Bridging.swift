#if canImport(Network) && canImport(dnssd)

    import Foundation
    import Network
    import dnssd

    // MARK: - Replies

    extension BonjourDiscovery {
        /// One `DNSServiceRegisterReply`, copied out of the C callback's
        /// arguments before they go out of scope.
        struct RegistrationReply: Sendable {
            /// Carried rather than dropped because it is what tells a
            /// registration going in from one coming back out.
            /// dns_sd.h:1275-1284: a name that registers is reported with
            /// `kDNSServiceFlagsAdd` set, and one that "later suffers a name
            /// conflict or similar problem and has to be deregistered" is
            /// reported with the same flag not set.
            let flags: DNSServiceFlags
            let errorCode: DNSServiceErrorType
            let name: String
            let serviceType: String
            let domain: String

            /// dns_sd.h:230-232 asks for the bit rather than the whole field:
            /// "code that tests `if (flags == kDNSServiceFlagsAdd)` will fail
            /// if, in a future release, another bit in the 32-bit flags field
            /// is also set."
            var isAdd: Bool { flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 }
        }

        /// One `DNSServiceResolveReply`, likewise.
        struct ResolutionReply: Sendable {
            let errorCode: DNSServiceErrorType
            let hostTarget: String
            /// Host byte order. The callback reports it in network byte order.
            let port: UInt16
            let txtRecord: Data
        }

        /// Non-capturing on purpose: a dns_sd callback is a C function pointer,
        /// and the sink reached through `context` is the only channel back.
        static let registrationReply: DNSServiceRegisterReply =
            { _, flags, errorCode, name, serviceType, domain, context in
                guard let sink = DNSServiceReplySink<RegistrationReply>.sink(for: context) else {
                    return
                }
                sink.continuation.yield(
                    RegistrationReply(
                        flags: flags,
                        errorCode: errorCode,
                        name: BonjourDiscovery.string(name),
                        serviceType: BonjourDiscovery.string(serviceType),
                        domain: BonjourDiscovery.string(domain)
                    ))
            }

        static let resolutionReply: DNSServiceResolveReply =
            { _, _, _, errorCode, _, hostTarget, port, txtLength, txtRecord, context in
                guard let sink = DNSServiceReplySink<ResolutionReply>.sink(for: context) else {
                    return
                }
                // Copied rather than referenced: the pointer is only valid for
                // the duration of the callback.
                let bytes =
                    txtRecord.map { Data(UnsafeBufferPointer(start: $0, count: Int(txtLength))) }
                    ?? Data()
                sink.continuation.yield(
                    ResolutionReply(
                        errorCode: errorCode,
                        hostTarget: BonjourDiscovery.string(hostTarget),
                        port: UInt16(bigEndian: port),
                        txtRecord: bytes
                    ))
            }

        /// Reads a C string the responder handed back.
        ///
        /// An absent or non-UTF-8 string becomes empty rather than discarding
        /// the callback: the fields this reads are labels, and a peer with an
        /// odd name is still a peer.
        static func string(_ pointer: UnsafePointer<CChar>?) -> String {
            guard let pointer else { return "" }
            return String(validatingCString: pointer) ?? ""
        }

        /// dns_sd.h's `kDNSServiceErr_` constants import as `Int`, while every
        /// function that produces one returns `DNSServiceErrorType`, which is
        /// `Int32`. Converted once here rather than at each comparison.
        enum Status {
            static let noError = DNSServiceErrorType(kDNSServiceErr_NoError)
            static let badParam = DNSServiceErrorType(kDNSServiceErr_BadParam)
            static let nameConflict = DNSServiceErrorType(kDNSServiceErr_NameConflict)
            static let alreadyRegistered = DNSServiceErrorType(kDNSServiceErr_AlreadyRegistered)
            static let serviceNotRunning = DNSServiceErrorType(kDNSServiceErr_ServiceNotRunning)
            static let policyDenied = DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
            static let noAuth = DNSServiceErrorType(kDNSServiceErr_NoAuth)
            static let noSuchName = DNSServiceErrorType(kDNSServiceErr_NoSuchName)
            static let timeout = DNSServiceErrorType(kDNSServiceErr_Timeout)
            static let noRouter = DNSServiceErrorType(kDNSServiceErr_NoRouter)
        }

        /// A table rather than a `switch`: every arm was one constant mapped to
        /// one string, which is data, and reading it as data makes it obvious
        /// that nothing here branches.
        private static let statusMessages: [DNSServiceErrorType: String] = [
            Status.noError: "no error",
            Status.nameConflict: "the service name is already taken",
            Status.alreadyRegistered: "this service is already registered",
            Status.serviceNotRunning: "mDNSResponder is not running",
            Status.policyDenied: "local network access is denied to this app",
            Status.noAuth: "mDNSResponder refused this process",
            Status.noSuchName: "no such service",
            Status.timeout: "mDNSResponder timed out",
            Status.noRouter: "no network connection",
        ]

        /// The code itself for anything unnamed — a responder error this build
        /// has no wording for is still worth reporting.
        static func message(for status: DNSServiceErrorType) -> String {
            statusMessages[status] ?? "mDNSResponder error \(status)"
        }
    }

    // MARK: - NWBrowser results

    extension BonjourDiscovery {
        static func event(for change: NWBrowser.Result.Change) -> DiscoveryEvent? {
            switch change {
            case .added(let result): peer(from: result).map(DiscoveryEvent.appeared)
            case .removed(let result): peer(from: result).map(DiscoveryEvent.disappeared)
            case .changed(_, let new, _): peer(from: new).map(DiscoveryEvent.changed)
            case .identical: nil
            @unknown default: nil
            }
        }

        /// `nil` for a result that is not a Bonjour service — the browser can
        /// also report `applicationService` endpoints, which this build does
        /// not ask for and would not know what to do with.
        static func peer(from result: NWBrowser.Result) -> DiscoveredPeer? {
            guard case .service(let name, let type, let domain, let interface) = result.endpoint
            else { return nil }
            return DiscoveredPeer(
                instanceName: name,
                serviceType: type,
                domain: domain,
                interfaceIndex: interface.flatMap { UInt32(exactly: $0.index) },
                advertisement: advertisement(from: result.metadata)
            )
        }

        /// `.unread` only where the browser genuinely delivered no record —
        /// which for `.bonjourWithTXTRecord` means the peer advertised none.
        static func advertisement(
            from metadata: NWBrowser.Result.Metadata
        ) -> DiscoveredPeer.AdvertisementState {
            guard case .bonjour(let record) = metadata else { return .unread }
            do {
                return .read(try PeerAdvertisement(dnsSDWireFormat: record.data))
            } catch let error as AdvertisementError {
                return .unreadable(error)
            } catch {
                return .unreadable(.malformedRecord(reason: String(describing: error)))
            }
        }
    }

#endif

#if canImport(Network) && canImport(dnssd)

    import Foundation
    import Network
    import dnssd

    /// ``PeerDiscovery`` on macOS, over Bonjour.
    ///
    /// Two APIs rather than one, and the split is not a preference.
    ///
    /// **Publishing does not use `NWListener`.** An `NWListener` binds a socket
    /// of its own, and the sync transport is swift-nio, which already owns the
    /// port being advertised. Measured on macOS 26 against a plain POSIX
    /// listener holding port 7311: `NWListener` reports
    /// `failed(POSIXErrorCode(rawValue: 48): Address already in use)`, with
    /// `NWParameters.allowLocalEndpointReuse` set and unset alike.
    /// `DNSServiceRegister` is the API for this case — it registers a record
    /// for a port somebody else is listening on and binds nothing — and it
    /// registered against that same held port with no error.
    ///
    /// **Browsing uses `NWBrowser`,** which handles interface churn and
    /// delivers set differences rather than raw add and remove flags. It must
    /// be `.bonjourWithTXTRecord` and not `.bonjour`: both cases take the same
    /// two associated values, so the wrong one compiles, and the only symptom
    /// is `NWBrowser.Result.metadata` arriving as `.none` forever.
    ///
    /// `NWBrowser` stops one step short of what swift-nio needs — its results
    /// are `NWEndpoint.service(name:type:domain:interface:)`, with no host and
    /// no port — so ``resolve(_:timeout:)`` finishes the job with
    /// `DNSServiceResolve`.
    ///
    /// Nothing here sets `includePeerToPeer`. It lives on `NWParameters` and
    /// already reads `false` for `NWParameters.tcp`, so AWDL — Apple-only, and
    /// useless to a Linux peer — stays out of the way by being left alone. The
    /// sentence exists because a deliberate omission is otherwise invisible.
    ///
    /// The three halves live in `BonjourDiscovery+Advertising.swift`,
    /// `BonjourDiscovery+Browsing.swift` and `BonjourDiscovery+Resolution.swift`,
    /// with the C and `NWBrowser` translation in `BonjourDiscovery+Bridging.swift`.
    /// One file held all four and went past the file- and type-length ceilings.
    ///
    /// The caller owns the lifetime: an instance that is dropped without
    /// ``stopAdvertising()`` and ``stopBrowsing()`` leaks its `DNSServiceRef`,
    /// because an actor's `deinit` cannot touch isolated state.
    public actor BonjourDiscovery: PeerDiscovery {
        /// How long the responder gets to confirm a registration.
        static let registrationTimeout: Duration = .seconds(10)

        /// Every responder callback lands here.
        ///
        /// One serial queue because dns_sd.h's "Thread Safety" note requires
        /// that `DNSServiceRefDeallocate` run on the same queue that was passed
        /// to `DNSServiceSetDispatchQueue`, and because nothing scheduled on it
        /// blocks: each callback copies its arguments into an `AsyncStream`
        /// continuation and returns.
        let queue = DispatchQueue(label: "dev.soldunov.skrepka.discovery")

        // Everything below is internal rather than private on purpose: the
        // three halves of this actor live in their own files, and Swift's
        // `private` reaches an extension only inside the file it was written
        // in.

        var registrationRef: DNSServiceRef?
        var registrationSink: DNSServiceReplySink<RegistrationReply>?
        var registrationContext: UnsafeMutableRawPointer?

        /// Where ``advertisementFailures()`` subscribers are kept.
        var advertisementFanout = EventFanout<DiscoveryError>()

        public internal(set) var registration: ServiceRegistration?

        var browser: NWBrowser?

        /// The one stream the browser's two handlers write into.
        ///
        /// A single source drained by a single task, rather than the handlers
        /// yielding to each subscriber directly, because the handlers run on
        /// ``queue`` and the subscribers live on this actor: hopping per event
        /// with an unstructured `Task` would reorder them, and an `.appeared`
        /// delivered after its `.disappeared` is a peer that never goes away.
        var browseSource: AsyncStream<DiscoveryEvent>.Continuation?

        /// Where ``startBrowsing()`` subscribers are kept.
        var browseFanout = EventFanout<DiscoveryEvent>()

        public init() {}
    }

#endif

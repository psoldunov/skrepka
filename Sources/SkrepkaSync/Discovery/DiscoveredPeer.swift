import Foundation

/// A service instance a browse turned up, before it has been resolved to an
/// address.
///
/// The three name parts plus the interface are exactly what every DNS-SD
/// implementation needs to hand back to a resolver: `DNSServiceResolve` takes
/// `name`, `regtype`, `domain` and an interface index, and avahi's
/// `ServiceResolver` takes the same four.
public struct DiscoveredPeer: Sendable, Hashable {
    /// What a conformance knows about the peer's TXT record at browse time.
    ///
    /// Three states rather than an optional, because "the platform does not
    /// deliver TXT records until you resolve" and "the platform delivered one
    /// and it was nonsense" are different facts and only one of them is a
    /// problem to report.
    public enum AdvertisementState: Sendable, Hashable {
        /// Not delivered with the browse result. Call
        /// ``PeerDiscovery/resolve(_:timeout:)``.
        ///
        /// Where avahi's `ServiceBrowser` and a vendored mDNS responder both
        /// land: neither carries the TXT record until resolution. Bonjour's
        /// `NWBrowser` does, so the macOS conformance rarely produces this.
        case unread
        /// Delivered and read.
        case read(PeerAdvertisement)
        /// Delivered and unreadable. Kept against the peer instead of dropping
        /// it, so a machine with a broken record is visible and diagnosable
        /// rather than absent.
        case unreadable(AdvertisementError)
    }

    /// The DNS-SD instance name, which is a label rather than an identity — it
    /// gets renamed on collision. The peer's identity is the advertisement's
    /// ``PeerAdvertisement/deviceID``.
    public let instanceName: String

    /// Always ``ServiceDescriptor/serviceType`` in practice; carried because a
    /// resolver needs it back verbatim.
    public let serviceType: String

    /// Usually `local.`, and carried for the same reason.
    public let domain: String

    /// The network interface the peer was seen on, or `nil` for "any".
    ///
    /// `nil` rather than a magic number because the two implementations spell
    /// "any" differently — dns_sd uses `0`, avahi uses `-1` — and a protocol
    /// that picks one of them makes the other conformance translate a value
    /// that looks like it needs no translating.
    public let interfaceIndex: UInt32?

    public let advertisement: AdvertisementState

    public init(
        instanceName: String,
        serviceType: String,
        domain: String,
        interfaceIndex: UInt32?,
        advertisement: AdvertisementState
    ) {
        self.instanceName = instanceName
        self.serviceType = serviceType
        self.domain = domain
        self.interfaceIndex = interfaceIndex
        self.advertisement = advertisement
    }
}

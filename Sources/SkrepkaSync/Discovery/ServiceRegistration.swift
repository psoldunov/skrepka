import Foundation

/// What a responder actually published, which is not always what was asked for.
///
/// DNS-SD renames an instance whose name is already taken — two Macs both
/// called "MacBook Pro" become "MacBook Pro" and "MacBook Pro (2)". Skrepka
/// lets that happen rather than passing `kDNSServiceFlagsNoAutoRename`, because
/// the instance name is a label and the identity is `id=` in the TXT record: a
/// collision that renames costs a cosmetic difference, and a collision that
/// fails registration costs the whole device. The consequence is that the
/// granted name has to be read back rather than assumed, which is what this
/// type is for.
public struct ServiceRegistration: Sendable, Hashable {
    /// The instance name the responder granted.
    public let name: String

    /// As the responder spelled it back, which is not always as it was asked
    /// for: mDNSResponder returns `_skrepka._tcp.` with a trailing dot, while
    /// the same type arrives from a browse as `_skrepka._tcp` without one.
    /// Compare against ``ServiceDescriptor/serviceType`` only after trimming.
    public let serviceType: String

    /// Usually `local.`.
    public let domain: String

    /// The port advertised — the one the transport is listening on.
    public let port: UInt16

    public init(name: String, serviceType: String, domain: String, port: UInt16) {
        self.name = name
        self.serviceType = serviceType
        self.domain = domain
        self.port = port
    }
}

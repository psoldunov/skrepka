import Foundation

/// What a live advertisement needs done to it before it describes a new
/// ``ServiceDescriptor``.
///
/// **Why this is a decision rather than "stop it and start it again".** The
/// obvious implementation withdraws the record and publishes a fresh one, and it
/// is wrong in a way that only shows up with two machines in the room: every
/// peer's browse sees the device disappear and come back. Opening the pairing
/// window, closing it again and rebinding the pinned listener afterwards is
/// three of those in one pairing, at least two of which change nothing but the
/// `pair=` key — so the device the user is trying to pair with blinks out of the
/// list twice while they are looking at it.
///
/// dns_sd.h's `DNSServiceUpdateRecord` replaces the primary TXT record of a
/// registration in place (case 1 in its documentation, `recordRef` NULL), which
/// covers every change except the two that live outside the TXT record.
public enum AdvertisementChange: Sendable, Hashable {
    /// The published record already says this. Do nothing at all.
    case unchanged

    /// Only the TXT record differs, so it can be replaced in place and the
    /// service stays registered throughout.
    case record

    /// Something outside the TXT record differs, so the registration itself has
    /// to be withdrawn and made again.
    ///
    /// Two fields do this. The port is the SRV record, and the display name is
    /// the DNS-SD service instance name — the first argument `DNSServiceRegister`
    /// takes — and neither is a record `DNSServiceUpdateRecord` can reach.
    case republish

    /// What has to happen for the advertisement to say `wanted` instead of
    /// `published`.
    public static func between(
        published: ServiceDescriptor,
        wanted: ServiceDescriptor
    ) -> AdvertisementChange {
        guard published != wanted else { return .unchanged }
        // Compared after equality rather than instead of it: two descriptors
        // that differ in neither of these differ somewhere in the TXT record,
        // which is the whole of the rest of the type.
        guard published.port == wanted.port, published.displayName == wanted.displayName else {
            return .republish
        }
        return .record
    }
}

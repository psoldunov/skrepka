import Foundation
import SkrepkaSync

/// What one peer's TXT record browser has said so far, and what the next
/// signal from it means.
///
/// ## Why a record browser at all
///
/// A Mac opens its pairing window by rewriting its TXT record **in place** —
/// `DNSServiceUpdateRecord` adds `pair=<port>` — and avahi's `ServiceBrowser`
/// says nothing about that: `avahi-core/browse-service.c` keys on the PTR
/// record alone, and the PTR did not change. A one-shot resolve at `ItemNew`
/// therefore froze every Mac's record as it was when it was first seen, and a
/// Mac that started pairing afterwards stayed "not accepting pairings" on this
/// side for good. A long-lived `RecordBrowser` on the instance's TXT record is
/// the change feed avahi does offer.
///
/// ## The rules, from how avahi's cache reports a change
///
/// - **The latest `ItemNew` is the record.** A fresh browser replays the
///   cached record first, and a cache-flush update arrives as `ItemNew` for the
///   new rdata before `ItemRemove` for the old one (`avahi-core/cache.c`).
/// - **An `ItemRemove` only matters for the current rdata**, and even then it
///   reports nothing: the old record expiring behind a newer one is exactly the
///   second half of an update, and a peer that really left is the service
///   browser's `ItemRemove` to report, not this one's.
/// - **Only a change is news.** The same advertisement arriving again — a
///   re-announcement, the replay after a restart — is not reported twice.
///
/// A value type rather than state on the actor, so the rules above are tested
/// without a daemon.
struct PeerRecordWatch: Sendable, Hashable {
    /// What the next `ItemNew` means to a caller.
    enum Outcome: Sendable, Hashable {
        case unchanged
        case changed(PeerAdvertisement)
        case unreadable(AdvertisementError)
    }

    /// The browse result the watch belongs to, carried so a change can be
    /// reported as the same peer with a new advertisement.
    let peer: DiscoveredPeer
    /// The rdata of the record avahi currently holds, or nil before the first
    /// `ItemNew` and after the current record expired.
    let current: [UInt8]?
    /// The advertisement last reported, so an unchanged one is not reported
    /// again.
    let reported: PeerAdvertisement?

    init(peer: DiscoveredPeer, current: [UInt8]? = nil, reported: PeerAdvertisement? = nil) {
        self.peer = peer
        self.current = current
        self.reported = reported
    }

    /// A record arrived.
    func arriving(_ rdata: [UInt8]) -> (watch: PeerRecordWatch, outcome: Outcome) {
        guard rdata != current else { return (self, .unchanged) }
        let advertisement: PeerAdvertisement
        do {
            advertisement = try PeerAdvertisement(dnsSDWireFormat: Data(rdata))
        } catch {
            let reason = (error as? AdvertisementError) ?? .malformedRecord(reason: "\(error)")
            return (PeerRecordWatch(peer: peer, current: rdata, reported: reported), .unreadable(reason))
        }
        let next = PeerRecordWatch(peer: peer, current: rdata, reported: advertisement)
        return (next, advertisement == reported ? .unchanged : .changed(advertisement))
    }

    /// A record expired or was withdrawn.
    func leaving(_ rdata: [UInt8]) -> PeerRecordWatch {
        guard rdata == current else { return self }
        return PeerRecordWatch(peer: peer, current: nil, reported: reported)
    }

    /// The browse result to report a changed advertisement under.
    func changedPeer(_ advertisement: PeerAdvertisement) -> DiscoveredPeer {
        DiscoveredPeer(
            instanceName: peer.instanceName,
            serviceType: peer.serviceType,
            domain: peer.domain,
            interfaceIndex: peer.interfaceIndex,
            advertisement: .read(advertisement)
        )
    }
}

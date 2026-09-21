import Foundation
import SkrepkaSync

/// Every record skrepkad answers for on one interface, and the messages built
/// from them.
///
/// The set RFC 6763 describes for one service instance:
///
/// - `_skrepka._tcp.local. PTR <instance>._skrepka._tcp.local.` — §4.1, the
///   browse record. **Shared**: many hosts hold records under that name.
/// - `_services._dns-sd._udp.local. PTR _skrepka._tcp.local.` — §9, service
///   type enumeration. Shared.
/// - `<instance> SRV 0 0 <port> <host>.local.` and `<instance> TXT …` — §5
///   and §6. **Unique**: the name is this host's alone, so they carry the
///   cache-flush bit (RFC 6762 §10.2).
/// - `<host>.local. A <address>` — RFC 6762 §6.2 answers with the addresses of
///   the interface the query arrived on, which is why this set is built per
///   interface. Unique.
///
/// TTLs are RFC 6762 §10's: 120 seconds for a record that names a host or
/// has a host name in its rdata (SRV, A), 75 minutes for everything else.
struct MDNSServiceRecords: Sendable, Hashable {
    static let hostTTL: UInt32 = 120
    static let otherTTL: UInt32 = 4500

    /// `_skrepka._tcp.local.`, from ``SkrepkaSync/ServiceDescriptor/serviceType``.
    static let serviceType = DNSName(
        labelStrings: ServiceDescriptor.serviceType.split(separator: ".").map(String.init) + ["local"])
    /// RFC 6763 §9.
    static let enumeration = DNSName("_services", "_dns-sd", "_udp", "local")

    let instanceLabel: String
    let hostLabel: String
    let port: UInt16
    /// Wire-format TXT RDATA.
    let txt: [UInt8]
    /// The IPv4 addresses of this interface, four bytes each.
    let addresses: [[UInt8]]

    var instanceName: DNSName { Self.serviceType.prefixed(by: instanceLabel) }
    var hostName: DNSName { DNSName(hostLabel, "local") }

    var browseRecord: DNSRecord {
        DNSRecord(name: Self.serviceType, data: .ptr(instanceName), ttl: Self.otherTTL, cacheFlush: false)
    }

    var enumerationRecord: DNSRecord {
        DNSRecord(
            name: Self.enumeration, data: .ptr(Self.serviceType), ttl: Self.otherTTL, cacheFlush: false)
    }

    var serviceRecord: DNSRecord {
        let srv = DNSRecordData.SRV(priority: 0, weight: 0, port: port, target: hostName)
        return DNSRecord(name: instanceName, data: .srv(srv), ttl: Self.hostTTL, cacheFlush: true)
    }

    var textRecord: DNSRecord {
        DNSRecord(name: instanceName, data: .txt(txt), ttl: Self.otherTTL, cacheFlush: true)
    }

    var addressRecords: [DNSRecord] {
        addresses.map { DNSRecord(name: hostName, data: .ipv4($0), ttl: Self.hostTTL, cacheFlush: true) }
    }

    /// The records under the two names this host owns outright.
    var uniqueRecords: [DNSRecord] { [serviceRecord, textRecord] + addressRecords }

    var allRecords: [DNSRecord] { [browseRecord, enumerationRecord] + uniqueRecords }

    /// RFC 6762 §6.1's restricted NSEC for one of the two owned names: "these
    /// types exist here, and no others". Sent so a querier asking for AAAA of a
    /// host with no IPv6 address gets an answer instead of a timeout.
    func negativeRecord(for name: DNSName) -> DNSRecord? {
        let types: [UInt16]
        let ttl: UInt32
        if name.matches(hostName) {
            types = addresses.isEmpty ? [] : [DNSType.addressV4]
            ttl = Self.hostTTL
        } else if name.matches(instanceName) {
            types = [DNSType.txt, DNSType.srv]
            ttl = Self.otherTTL
        } else {
            return nil
        }
        return DNSRecord(name: name, data: .nsec(next: name, types: types), ttl: ttl, cacheFlush: true)
    }

    // MARK: - Messages

    /// RFC 6762 §8.3: every record, unsolicited, in the answer section.
    func announcement() -> DNSMessage {
        DNSMessage(flags: DNSMessage.responseFlags, answers: allRecords)
    }

    /// RFC 6762 §10.1: the same records with a TTL of zero, so every cache
    /// drops them now rather than in 75 minutes.
    ///
    /// All but the service-type enumeration PTR. Its rdata is
    /// `_skrepka._tcp.local.` whoever sends it, so every Skrepka device on the
    /// link holds the identical record, and a goodbye for it would delete the
    /// other devices' copy from every cache too.
    func goodbye() -> DNSMessage {
        let records = [browseRecord] + uniqueRecords
        return DNSMessage(flags: DNSMessage.responseFlags, answers: records.map { $0.with(ttl: 0) })
    }

    /// RFC 6762 §8.1: an ANY question for each name to be claimed, with the
    /// records this host proposes for them in the authority section.
    ///
    /// Sent as QM, not the QU §8.1 recommends, and deliberately: this socket
    /// is bound to the multicast group so that it never takes avahi's unicast
    /// traffic (see ``MDNSSocket``), which means a unicast defence would reach
    /// avahi and not here. A defender answering by multicast is heard.
    func probe() -> DNSMessage {
        DNSMessage(
            flags: DNSMessage.queryFlags,
            questions: [
                DNSQuestion(name: instanceName, type: DNSType.any),
                DNSQuestion(name: hostName, type: DNSType.any),
            ],
            authorities: uniqueRecords)
    }
}

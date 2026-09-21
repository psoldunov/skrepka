import Foundation

/// One resource record.
struct DNSRecord: Sendable, Hashable {
    let name: DNSName
    let data: DNSRecordData
    let recordClass: UInt16
    /// Seconds. Zero is a goodbye (RFC 6762 §10.1).
    let ttl: UInt32
    /// RFC 6762 §10.2: set on records this host owns outright, so a receiver
    /// replaces what it had for that name and type rather than adding to it.
    let cacheFlush: Bool

    init(
        name: DNSName,
        data: DNSRecordData,
        ttl: UInt32,
        cacheFlush: Bool,
        recordClass: UInt16 = DNSClass.internet
    ) {
        self.name = name
        self.data = data
        self.ttl = ttl
        self.cacheFlush = cacheFlush
        self.recordClass = recordClass
    }

    /// The same record with another TTL.
    func with(ttl: UInt32) -> DNSRecord {
        DNSRecord(name: name, data: data, ttl: ttl, cacheFlush: cacheFlush, recordClass: recordClass)
    }

    /// The same record, capped the way RFC 6762 §6.7 wants a legacy unicast
    /// answer: no cache-flush bit, and a TTL of at most `ttlCap`.
    func forLegacyUnicast(ttlCap: UInt32) -> DNSRecord {
        DNSRecord(
            name: name, data: data, ttl: min(ttl, ttlCap), cacheFlush: false, recordClass: recordClass)
    }

    /// Same name, type, class and rdata — the identity RFC 6762 §7.1
    /// (known answers) and §9 (conflicts) compare by. The TTL and the
    /// cache-flush bit are not part of it.
    func isSameRecord(as other: DNSRecord) -> Bool {
        name.matches(other.name) && recordClass == other.recordClass && data.isSame(as: other.data)
    }
}

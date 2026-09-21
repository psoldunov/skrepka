import Foundation

/// What to send back for a received query, as a pure function of the query,
/// where it came from and the records held.
///
/// Kept apart from the sockets so every rule below is tested on bytes alone.
enum MDNSAnswering {
    static let port = 5353
    /// RFC 6762 §6.7: a legacy unicast answer "SHOULD NOT be greater than ten
    /// seconds".
    static let legacyTTLCap: UInt32 = 10

    /// One message to send, and whether it goes back to the querier alone.
    struct Reply: Sendable, Hashable {
        let isUnicast: Bool
        let message: DNSMessage
    }

    /// The replies one query earns.
    ///
    /// - A query from a source port other than 5353 is a legacy resolver
    ///   (RFC 6762 §6.7): answered by unicast, repeating its ID and questions,
    ///   with no cache-flush bits and TTLs capped at ten seconds.
    /// - A QU question (§5.4) is answered by unicast only if this interface
    ///   has multicast its records recently — otherwise by multicast, "so as to
    ///   keep all the peer caches up to date". `multicastRecently` is the
    ///   caller's reading of that clock.
    /// - Anything else is answered by multicast, minus the answers the querier
    ///   said it already knows (§7.1).
    ///
    /// Deliberately not implemented, and what each costs:
    /// - §7.2's multipacket known-answer lists: a query with TC set is answered
    ///   at once rather than after waiting for its continuation packets, so a
    ///   querier with more known answers than fit one packet gets a redundant
    ///   answer. One service's worth of records never needs a second packet.
    /// - Per-record QU recency: `multicastRecently` is one clock per interface,
    ///   not one per record as §5.4 reads. A QU question can therefore be
    ///   answered by unicast for a record whose last multicast was longer ago
    ///   than a quarter of its TTL, leaving other caches that much staler.
    ///   Every record is announced together, so the clocks would rarely differ.
    static func replies(
        to query: DNSMessage,
        fromPort sourcePort: Int,
        records: MDNSServiceRecords,
        multicastRecently: Bool
    ) -> [Reply] {
        guard !query.isResponse, query.hasStandardOpcode else { return [] }
        if sourcePort != port { return legacyReply(to: query, records: records) }
        var unicast: [DNSRecord] = []
        var multicast: [DNSRecord] = []
        for question in query.questions {
            let found = answers(to: question, records: records, knownAnswers: query.answers)
            if question.wantsUnicastResponse, multicastRecently {
                unicast = merged(unicast, found)
            } else {
                multicast = merged(multicast, found)
            }
        }
        // One multicast reply reaches the querier too, so a unicast copy of
        // the same answers would be traffic for nothing.
        if !multicast.isEmpty {
            return [response(merged(multicast, unicast), records: records, isUnicast: false)]
        }
        return unicast.isEmpty ? [] : [response(unicast, records: records, isUnicast: true)]
    }

    /// RFC 6762 §6's matching, then §7.1's known-answer suppression, then —
    /// when nothing matched a name this host owns — §6.1's negative answer.
    static func answers(
        to question: DNSQuestion,
        records: MDNSServiceRecords,
        knownAnswers: [DNSRecord]
    ) -> [DNSRecord] {
        let matching = records.allRecords.filter { question.isAnswered(by: $0) }
        if matching.isEmpty {
            guard question.type != DNSType.any,
                question.recordClass == DNSClass.internet || question.recordClass == DNSClass.any,
                let negative = records.negativeRecord(for: question.name)
            else { return [] }
            return [negative]
        }
        return matching.filter { record in
            !knownAnswers.contains { $0.isSameRecord(as: record) && $0.ttl >= record.ttl / 2 }
        }
    }

    /// RFC 6763 §12: a PTR answer brings the instance's SRV and TXT and the
    /// host's addresses; an SRV answer brings the addresses. The host's NSEC
    /// rides along with its addresses, so a querier learns in the same packet
    /// that there is no AAAA to wait for (RFC 6762 §6.1).
    static func additionals(for answers: [DNSRecord], records: MDNSServiceRecords) -> [DNSRecord] {
        let hasBrowse = answers.contains { $0.isSameRecord(as: records.browseRecord) }
        let hasService = hasBrowse || answers.contains { $0.isSameRecord(as: records.serviceRecord) }
        var extra: [DNSRecord] = hasBrowse ? [records.serviceRecord, records.textRecord] : []
        if hasService {
            extra += records.addressRecords
            extra += [records.negativeRecord(for: records.hostName)].compactMap { $0 }
        }
        return extra.filter { record in !answers.contains { $0.isSameRecord(as: record) } }
    }

    private static func legacyReply(to query: DNSMessage, records: MDNSServiceRecords) -> [Reply] {
        let found = query.questions.reduce(into: [DNSRecord]()) { found, question in
            found = merged(found, answers(to: question, records: records, knownAnswers: []))
        }
        guard !found.isEmpty else { return [] }
        let capped = { (record: DNSRecord) in record.forLegacyUnicast(ttlCap: legacyTTLCap) }
        let message = DNSMessage(
            id: query.id,
            flags: DNSMessage.responseFlags,
            questions: query.questions,
            answers: found.map(capped),
            additionals: additionals(for: found, records: records).map(capped))
        return [Reply(isUnicast: true, message: message)]
    }

    private static func response(
        _ answers: [DNSRecord],
        records: MDNSServiceRecords,
        isUnicast: Bool
    ) -> Reply {
        let message = DNSMessage(
            flags: DNSMessage.responseFlags,
            answers: answers,
            additionals: additionals(for: answers, records: records))
        return Reply(isUnicast: isUnicast, message: message)
    }

    private static func merged(_ lhs: [DNSRecord], _ rhs: [DNSRecord]) -> [DNSRecord] {
        lhs + rhs.filter { record in !lhs.contains { $0.isSameRecord(as: record) } }
    }
}

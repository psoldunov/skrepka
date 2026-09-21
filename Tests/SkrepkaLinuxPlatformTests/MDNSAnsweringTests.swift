import Foundation
import Testing

@testable import SkrepkaLinuxPlatform

/// Which questions get which answers, by which route — RFC 6762 §5.4, §6,
/// §6.1, §6.7 and §7.1, and RFC 6763 §9 and §12.
@Suite("mDNS answering")
struct MDNSAnsweringTests {
    static let records = MDNSServiceRecords(
        instanceLabel: "steamdeck",
        hostLabel: "skrepka-0123abcd",
        port: 7011,
        txt: [9] + Array("txtvers=1".utf8),
        addresses: [[192, 168, 1, 50]]
    )

    static func query(_ questions: DNSQuestion..., known: [DNSRecord] = [], id: UInt16 = 0) -> DNSMessage {
        DNSMessage(id: id, flags: DNSMessage.queryFlags, questions: questions, answers: known)
    }

    static func only(_ replies: [MDNSAnswering.Reply]) throws -> MDNSAnswering.Reply {
        try #require(replies.count == 1)
        return replies[0]
    }

    @Test("a browse is answered by multicast, with SRV, TXT and the address beside it")
    func answersABrowse() throws {
        let question = DNSQuestion(name: MDNSServiceRecords.serviceType, type: DNSType.ptr)
        let reply = try Self.only(
            MDNSAnswering.replies(
                to: Self.query(question), fromPort: 5353, records: Self.records, multicastRecently: false))
        #expect(!reply.isUnicast)
        #expect(reply.message.isResponse)
        #expect(reply.message.questions.isEmpty)
        #expect(reply.message.answers == [Self.records.browseRecord])
        let extra = reply.message.additionals
        #expect(extra.contains(Self.records.serviceRecord))
        #expect(extra.contains(Self.records.textRecord))
        #expect(extra.contains(Self.records.addressRecords[0]))
        // The host has no AAAA, and its NSEC says so in the same packet.
        #expect(extra.contains { $0.data.type == DNSType.nsec && $0.name.matches(Self.records.hostName) })
    }

    @Test("service-type enumeration names _skrepka._tcp")
    func answersEnumeration() throws {
        let question = DNSQuestion(name: DNSName("_services", "_dns-sd", "_udp", "local"), type: DNSType.ptr)
        let reply = try Self.only(
            MDNSAnswering.replies(
                to: Self.query(question), fromPort: 5353, records: Self.records, multicastRecently: false))
        #expect(reply.message.answers == [Self.records.enumerationRecord])
        #expect(reply.message.additionals.isEmpty)
    }

    @Test("SRV brings the address; ANY on the instance brings SRV and TXT; names match case-insensitively")
    func answersInstanceQuestions() throws {
        let name = DNSName("SteamDeck", "_skrepka", "_TCP", "local")
        let srv = MDNSAnswering.answers(
            to: DNSQuestion(name: name, type: DNSType.srv), records: Self.records, knownAnswers: [])
        #expect(srv == [Self.records.serviceRecord])
        #expect(
            MDNSAnswering.additionals(for: srv, records: Self.records).contains(
                Self.records.addressRecords[0]))
        let any = MDNSAnswering.answers(
            to: DNSQuestion(name: name, type: DNSType.any), records: Self.records, knownAnswers: [])
        #expect(Set(any) == [Self.records.serviceRecord, Self.records.textRecord])
    }

    @Test("an AAAA question for the host gets an NSEC, not silence")
    func answersNegatively() {
        let aaaa = MDNSAnswering.answers(
            to: DNSQuestion(name: Self.records.hostName, type: DNSType.addressV6),
            records: Self.records,
            knownAnswers: []
        )
        #expect(aaaa.count == 1)
        #expect(aaaa.first?.data == .nsec(next: Self.records.hostName, types: [DNSType.addressV4]))
        let address = MDNSAnswering.answers(
            to: DNSQuestion(name: Self.records.hostName, type: DNSType.addressV4),
            records: Self.records,
            knownAnswers: []
        )
        #expect(address == Self.records.addressRecords)
    }

    @Test("a question about somebody else is not answered at all")
    func ignoresOtherNames() {
        let question = DNSQuestion(name: DNSName("_airplay", "_tcp", "local"), type: DNSType.ptr)
        #expect(
            MDNSAnswering.replies(
                to: Self.query(question), fromPort: 5353, records: Self.records, multicastRecently: false
            )
            .isEmpty)
        let other = DNSQuestion(name: DNSName("printer", "local"), type: DNSType.addressV6)
        #expect(MDNSAnswering.answers(to: other, records: Self.records, knownAnswers: []).isEmpty)
    }

    @Test("a known answer with at least half its TTL left suppresses the reply")
    func suppressesKnownAnswers() {
        let question = DNSQuestion(name: MDNSServiceRecords.serviceType, type: DNSType.ptr)
        let fresh = Self.records.browseRecord.with(ttl: 3000)
        #expect(
            MDNSAnswering.replies(
                to: Self.query(question, known: [fresh]),
                fromPort: 5353,
                records: Self.records,
                multicastRecently: false
            ).isEmpty)
        let stale = Self.records.browseRecord.with(ttl: 1000)
        #expect(
            MDNSAnswering.replies(
                to: Self.query(question, known: [stale]),
                fromPort: 5353,
                records: Self.records,
                multicastRecently: false
            ).count == 1)
    }

    @Test("QU is answered by unicast only when the records were multicast recently")
    func honoursUnicastRequests() throws {
        let question = DNSQuestion(
            name: MDNSServiceRecords.serviceType, type: DNSType.ptr, wantsUnicastResponse: true)
        let recent = try Self.only(
            MDNSAnswering.replies(
                to: Self.query(question), fromPort: 5353, records: Self.records, multicastRecently: true))
        #expect(recent.isUnicast)
        #expect(recent.message.answers.first?.cacheFlush == false)
        let stale = try Self.only(
            MDNSAnswering.replies(
                to: Self.query(question), fromPort: 5353, records: Self.records, multicastRecently: false))
        #expect(!stale.isUnicast)
    }

    @Test("a legacy query gets a unicast reply with its ID, its question, no cache-flush and short TTLs")
    func answersLegacyResolvers() throws {
        let question = DNSQuestion(name: Self.records.hostName, type: DNSType.addressV4)
        let reply = try Self.only(
            MDNSAnswering.replies(
                to: Self.query(question, id: 0xBEEF),
                fromPort: 49152,
                records: Self.records,
                multicastRecently: false
            ))
        #expect(reply.isUnicast)
        #expect(reply.message.id == 0xBEEF)
        #expect(reply.message.questions == [question])
        #expect(reply.message.answers.allSatisfy { !$0.cacheFlush && $0.ttl <= 10 })
        #expect(reply.message.answers.map(\.data) == [.ipv4([192, 168, 1, 50])])
    }

    @Test("a response is never answered, nor a message with a non-zero opcode")
    func ignoresNonQueries() {
        let question = DNSQuestion(name: MDNSServiceRecords.serviceType, type: DNSType.ptr)
        let response = DNSMessage(flags: DNSMessage.responseFlags, questions: [question])
        #expect(
            MDNSAnswering.replies(
                to: response, fromPort: 5353, records: Self.records, multicastRecently: false
            ).isEmpty)
        let update = DNSMessage(flags: 5 << 11, questions: [question])
        #expect(
            MDNSAnswering.replies(to: update, fromPort: 5353, records: Self.records, multicastRecently: false)
                .isEmpty)
    }
}

import Foundation
import Testing

@testable import SkrepkaLinuxPlatform

/// RFC 6762 §8.1 and §9, as ``MDNSConflict`` reads them.
@Suite("mDNS conflicts")
struct MDNSConflictTests {
    static let records = MDNSRecordsTests.records

    static func response(_ records: DNSRecord...) -> DNSMessage {
        DNSMessage(flags: DNSMessage.responseFlags, answers: records)
    }

    @Test("another host's SRV for the instance name is a conflict")
    func seesARival() {
        let rival = DNSRecord(
            name: Self.records.instanceName,
            data: .srv(.init(priority: 0, weight: 0, port: 7011, target: DNSName("steamdeck", "local"))),
            ttl: 120,
            cacheFlush: true
        )
        #expect(MDNSConflict.isConflicting(Self.response(rival), with: Self.records, probing: false))
        #expect(MDNSConflict.isConflicting(Self.response(rival), with: Self.records, probing: true))
    }

    @Test("while probing, any type under a claimed name conflicts; once established, only the same type")
    func probingIsStricter() {
        let hinfo = DNSRecord(
            name: Self.records.hostName, data: .other(type: 13, rdata: [0, 0]), ttl: 120, cacheFlush: true)
        #expect(MDNSConflict.isConflicting(Self.response(hinfo), with: Self.records, probing: true))
        #expect(!MDNSConflict.isConflicting(Self.response(hinfo), with: Self.records, probing: false))
    }

    @Test("identical records, goodbyes, shared PTRs and queries are not conflicts")
    func ignoresTheHarmless() {
        #expect(!MDNSConflict.isConflicting(Self.records.announcement(), with: Self.records, probing: true))
        let goodbye = Self.records.serviceRecord.with(ttl: 0)
        let changedGoodbye = DNSRecord(
            name: Self.records.instanceName, data: .txt([0]), ttl: 0, cacheFlush: true)
        #expect(
            !MDNSConflict.isConflicting(
                Self.response(goodbye, changedGoodbye), with: Self.records, probing: true))
        let otherInstance = DNSRecord(
            name: MDNSServiceRecords.serviceType,
            data: .ptr(DNSName("Mac", "_skrepka", "_tcp", "local")),
            ttl: 4500,
            cacheFlush: false
        )
        #expect(!MDNSConflict.isConflicting(Self.response(otherInstance), with: Self.records, probing: false))
        #expect(!MDNSConflict.isConflicting(Self.records.probe(), with: Self.records, probing: true))
    }

    @Test("this host's own address from its other interface is not a rival")
    func knowsItsOwnAddresses() {
        let otherInterface = DNSRecord(
            name: Self.records.hostName, data: .ipv4([10, 0, 0, 5]), ttl: 120, cacheFlush: true)
        #expect(
            !MDNSConflict.isConflicting(Self.response(otherInterface), with: Self.records, probing: false))
        let stranger = DNSRecord(
            name: Self.records.hostName, data: .ipv4([10, 0, 0, 9]), ttl: 120, cacheFlush: true)
        #expect(MDNSConflict.isConflicting(Self.response(stranger), with: Self.records, probing: false))
    }
}

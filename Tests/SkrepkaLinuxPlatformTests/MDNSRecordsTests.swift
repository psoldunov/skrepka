import Foundation
import SkrepkaSync
import Testing

@testable import SkrepkaLinuxPlatform

/// The records skrepkad publishes by itself, the messages built from them, and
/// the names they are published under.
@Suite("mDNS records, announcements and names")
struct MDNSRecordsTests {
    static let records = MDNSServiceRecords(
        instanceLabel: "steamdeck",
        hostLabel: "skrepka-0123abcd",
        port: 7011,
        txt: [9] + Array("txtvers=1".utf8),
        addresses: [[192, 168, 1, 50], [10, 0, 0, 5]]
    )

    @Test("an announcement carries every record, cache-flush on the unique ones, RFC 6762 §10 TTLs")
    func announces() throws {
        let message = Self.records.announcement()
        #expect(message.isResponse)
        #expect(message.id == 0)
        #expect(message.questions.isEmpty)
        #expect(message.answers.count == 6)
        for record in message.answers {
            let isShared = record.data.type == DNSType.ptr
            #expect(record.cacheFlush == !isShared)
            let hostBearing = [DNSType.srv, DNSType.addressV4].contains(record.data.type)
            #expect(record.ttl == (hostBearing ? 120 : 4500))
        }
        #expect(try DNSReader.decode(DNSWriter.encode(message)) == message)
    }

    @Test("the SRV points at the device's own host name and port")
    func pointsAtItsOwnHost() {
        let expected = DNSRecordData.SRV(
            priority: 0, weight: 0, port: 7011, target: DNSName("skrepka-0123abcd", "local"))
        #expect(Self.records.serviceRecord.data == .srv(expected))
        #expect(Self.records.instanceName == DNSName("steamdeck", "_skrepka", "_tcp", "local"))
    }

    @Test("a goodbye repeats the records with TTL 0, and leaves the shared enumeration PTR alone")
    func saysGoodbye() {
        let goodbye = Self.records.goodbye()
        #expect(goodbye.isResponse)
        #expect(goodbye.answers.allSatisfy { $0.ttl == 0 })
        #expect(goodbye.answers.contains { $0.isSameRecord(as: Self.records.browseRecord) })
        #expect(!goodbye.answers.contains { $0.isSameRecord(as: Self.records.enumerationRecord) })
        #expect(goodbye.answers.count == Self.records.allRecords.count - 1)
    }

    @Test("a probe asks ANY for both names and proposes the unique records")
    func probes() {
        let probe = Self.records.probe()
        #expect(!probe.isResponse)
        #expect(probe.questions.map(\.type) == [DNSType.any, DNSType.any])
        #expect(probe.questions.map(\.name) == [Self.records.instanceName, Self.records.hostName])
        #expect(probe.questions.allSatisfy { !$0.wantsUnicastResponse })
        #expect(probe.authorities == Self.records.uniqueRecords)
        #expect(probe.answers.isEmpty)
    }

    @Test("the host name is derived from the device ID, and renames count upwards")
    func namesTheDevice() throws {
        let id = try #require(SyncDeviceID(hex: "abcdef01" + String(repeating: "2", count: 56)))
        #expect(MDNSNaming.hostLabel(for: id, attempt: 1) == "skrepka-abcdef01")
        #expect(MDNSNaming.hostLabel(for: id, attempt: 3) == "skrepka-abcdef01-3")
        let deck = ServiceDescriptor(displayName: "steamdeck", port: 1, deviceID: id, platform: .linux)
        #expect(MDNSNaming.instanceLabel(for: deck, attempt: 1) == "steamdeck")
        #expect(MDNSNaming.instanceLabel(for: deck, attempt: 2) == "steamdeck #2")
        let unnamed = ServiceDescriptor(displayName: "", port: 1, deviceID: id, platform: .linux)
        #expect(MDNSNaming.instanceLabel(for: unnamed, attempt: 1) == "skrepka-abcdef01")
        let long = ServiceDescriptor(
            displayName: String(repeating: "é", count: 31), port: 1, deviceID: id, platform: .linux)
        let renamed = MDNSNaming.instanceLabel(for: long, attempt: 2)
        #expect(renamed.utf8.count <= DNSName.maximumLabelBytes)
        #expect(renamed.hasSuffix(" #2"))
    }
}

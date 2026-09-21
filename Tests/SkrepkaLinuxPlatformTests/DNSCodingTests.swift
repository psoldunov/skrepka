import Foundation
import Testing

@testable import SkrepkaLinuxPlatform

/// The DNS wire codec the mDNS responder speaks, on bytes alone.
@Suite("DNS message coding")
struct DNSCodingTests {
    static let instance = DNSName("kavallaris", "_skrepka", "_tcp", "local")
    static let host = DNSName("skrepka-0123abcd", "local")

    /// One of every record type, the cache-flush and QU bits both used.
    static func sampleMessage() -> DNSMessage {
        let srv = DNSRecordData.SRV(priority: 0, weight: 0, port: 7011, target: Self.host)
        return DNSMessage(
            id: 0x1234,
            flags: DNSMessage.responseFlags,
            questions: [
                DNSQuestion(
                    name: MDNSServiceRecords.serviceType, type: DNSType.ptr, wantsUnicastResponse: true)
            ],
            answers: [
                DNSRecord(
                    name: MDNSServiceRecords.serviceType,
                    data: .ptr(Self.instance),
                    ttl: 4500,
                    cacheFlush: false
                ),
                DNSRecord(name: Self.instance, data: .srv(srv), ttl: 120, cacheFlush: true),
                DNSRecord(
                    name: Self.instance,
                    data: .txt([9] + Array("txtvers=1".utf8)),
                    ttl: 4500,
                    cacheFlush: true
                ),
            ],
            authorities: [
                DNSRecord(name: Self.host, data: .ipv4([192, 168, 1, 7]), ttl: 120, cacheFlush: true)
            ],
            additionals: [
                DNSRecord(
                    name: Self.host,
                    data: .ipv6(Array(repeating: 0xFE, count: 16)),
                    ttl: 120,
                    cacheFlush: true
                ),
                DNSRecord(
                    name: Self.host,
                    data: .nsec(next: Self.host, types: [DNSType.addressV4]),
                    ttl: 120,
                    cacheFlush: true
                ),
            ])
    }

    @Test("every record type round-trips, cache-flush bit and QU bit included")
    func roundTrips() throws {
        let message = Self.sampleMessage()
        let decoded = try DNSReader.decode(DNSWriter.encode(message))
        // NSEC is read back as opaque rdata — the responder never needs to
        // parse one — so compare everything else structurally.
        #expect(decoded.id == 0x1234)
        #expect(decoded.isResponse)
        #expect(decoded.questions == message.questions)
        #expect(decoded.answers == message.answers)
        #expect(decoded.authorities == message.authorities)
        #expect(decoded.additionals.first == message.additionals.first)
        #expect(
            decoded.additionals.last?.data
                == .other(type: DNSType.nsec, rdata: DNSWriter.rdata(message.additionals[1].data)))
    }

    @Test("the cache-flush bit is the top bit of the class on the wire")
    func writesTheCacheFlushBit() {
        let record = DNSRecord(
            name: DNSName("a", "local"), data: .ipv4([10, 0, 0, 1]), ttl: 120, cacheFlush: true)
        let bytes = DNSWriter.encode(DNSMessage(flags: DNSMessage.responseFlags, answers: [record]))
        // Header, then `\x01a\x05local\x00` (9 bytes), type, class.
        let classOffset = 12 + 9 + 2
        #expect(bytes[classOffset] == 0x80)
        #expect(bytes[classOffset + 1] == 0x01)
    }

    @Test("NSEC uses the restricted window-0 bitmap RFC 6762 §6.1 requires")
    func writesNSECBitmaps() {
        #expect(DNSWriter.nsecBitmap([DNSType.addressV4]) == [0, 1, 0x40])
        // TXT is 16 (byte 2, top bit), SRV is 33 (byte 4, second bit).
        #expect(DNSWriter.nsecBitmap([DNSType.txt, DNSType.srv]) == [0, 5, 0, 0, 0x80, 0, 0x40])
    }

    @Test("compressed names are followed, including inside PTR and SRV rdata")
    func readsCompressedNames() throws {
        var bytes: [UInt8] = [0, 0, 0x84, 0, 0, 1, 0, 2, 0, 0, 0, 0]
        // A question at offset 12: `_skrepka._tcp.local.` PTR IN.
        bytes += [8] + Array("_skrepka".utf8) + [4] + Array("_tcp".utf8) + [5] + Array("local".utf8) + [0]
        bytes += [0, 12, 0, 1]
        // PTR answer: name → 12, rdata `\x03Mac` + pointer to 12.
        let ptrRdata: [UInt8] = [3] + Array("Mac".utf8) + [0xC0, 12]
        bytes += [0xC0, 12, 0, 12, 0, 1, 0, 0, 0x11, 0x94, 0, UInt8(ptrRdata.count)] + ptrRdata
        // SRV answer: name → the `Mac` label inside the PTR rdata, target
        // `\x04host` + pointer to `local` at offset 12 + 9 + 5.
        let macOffset = UInt8(bytes.count - ptrRdata.count)
        let srvRdata: [UInt8] = [0, 0, 0, 0, 0x1B, 0x63, 4] + Array("host".utf8) + [0xC0, 26]
        bytes += [0xC0, macOffset, 0, 33, 0x80, 1, 0, 0, 0, 120, 0, UInt8(srvRdata.count)] + srvRdata

        let message = try DNSReader.decode(bytes)
        #expect(message.questions.map(\.name) == [MDNSServiceRecords.serviceType])
        #expect(message.answers.count == 2)
        #expect(message.answers[0].data == .ptr(DNSName("Mac", "_skrepka", "_tcp", "local")))
        #expect(message.answers[1].name.matches(DNSName("MAC", "_SKREPKA", "_tcp", "local")))
        #expect(message.answers[1].cacheFlush)
        let target = DNSName("host", "local")
        #expect(message.answers[1].data == .srv(.init(priority: 0, weight: 0, port: 7011, target: target)))
    }

    @Test("a forward or self-referencing pointer is refused, not followed")
    func refusesPointerLoops() {
        let header: [UInt8] = [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        #expect(throws: DNSReader.Failure.badPointer) {
            try DNSReader.decode(header + [0xC0, 12, 0, 1, 0, 1])
        }
        #expect(throws: DNSReader.Failure.badPointer) {
            try DNSReader.decode(header + [0xC0, 40, 0, 1, 0, 1])
        }
    }

    @Test("a label loop between backward pointers ends at the length cap")
    func boundsLabelLoops() {
        // `\x01a` then a pointer back to it: a name that never ends.
        let header: [UInt8] = [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        #expect(throws: DNSReader.Failure.nameTooLong) {
            try DNSReader.decode(header + [1, 0x61, 0xC0, 12, 0, 1, 0, 1])
        }
    }

    @Test("a PTR whose name overruns or falls short of its RDLENGTH is refused")
    func refusesRdataLengthMismatch() {
        let header: [UInt8] = [0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0]
        let owner: [UInt8] = [1, 0x61, 0, 0, 12, 0, 1, 0, 0, 0, 120]
        // RDLENGTH 2, but `\x01b\x00` is three bytes: the name borrows a byte.
        #expect(throws: DNSReader.Failure.badLength) {
            try DNSReader.decode(header + owner + [0, 2, 1, 0x62, 0])
        }
        // RDLENGTH 4, and the name ends after three.
        #expect(throws: DNSReader.Failure.badLength) {
            try DNSReader.decode(header + owner + [0, 4, 1, 0x62, 0, 0])
        }
        #expect(throws: Never.self) { try DNSReader.decode(header + owner + [0, 3, 1, 0x62, 0]) }
    }

    @Test("a packet cut short is refused")
    func refusesTruncation() {
        #expect(throws: DNSReader.Failure.truncated) { try DNSReader.decode([0, 0, 0]) }
        let header: [UInt8] = [0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0]
        // An A record claiming 4 bytes of rdata and carrying 2.
        #expect(throws: DNSReader.Failure.truncated) {
            try DNSReader.decode(header + [1, 0x61, 0, 0, 1, 0, 1, 0, 0, 0, 120, 0, 4, 10, 0])
        }
    }

    @Test("names compare case-insensitively for ASCII only")
    func comparesNamesTheMDNSWay() {
        #expect(DNSName("Kavallaris", "LOCAL").matches(DNSName("kavallaris", "local")))
        #expect(!DNSName("É", "local").matches(DNSName("é", "local")))
        #expect(!DNSName("a", "local").matches(DNSName("a", "b", "local")))
    }
}

import Foundation

/// Reads a ``DNSMessage`` from RFC 1035 §4.1 wire form, compression included.
///
/// Everything arriving on UDP 5353 is untrusted: any host on the link can send
/// anything. So every length is checked against the packet before it is used,
/// and a compression pointer may only point **backwards** — RFC 1035 §4.1.4
/// has pointers refer to "a prior occurrence of the same name", so a forward
/// one is refused — see ``name()`` for why that and the length cap together
/// end every loop.
struct DNSReader {
    enum Failure: Error, Equatable {
        case truncated
        case badLabel
        case badPointer
        case nameTooLong
        /// A record whose RDATA, as parsed, does not end where its RDLENGTH
        /// says: a name in it ran on into the next record, or stopped short.
        case badLength
    }

    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    static func decode(_ bytes: [UInt8]) throws(Failure) -> DNSMessage {
        var reader = DNSReader(bytes)
        return try reader.message()
    }

    mutating func message() throws(Failure) -> DNSMessage {
        let id = try uint16()
        let flags = try uint16()
        let counts = [try uint16(), try uint16(), try uint16(), try uint16()]
        var questions: [DNSQuestion] = []
        for _ in 0..<counts[0] { questions.append(try question()) }
        var sections: [[DNSRecord]] = [[], [], []]
        for section in 0..<3 {
            for _ in 0..<counts[section + 1] { sections[section].append(try record()) }
        }
        return DNSMessage(
            id: id,
            flags: flags,
            questions: questions,
            answers: sections[0],
            authorities: sections[1],
            additionals: sections[2]
        )
    }

    mutating func question() throws(Failure) -> DNSQuestion {
        let name = try name()
        let type = try uint16()
        let rawClass = try uint16()
        return DNSQuestion(
            name: name,
            type: type,
            recordClass: rawClass & ~DNSClass.topBit,
            wantsUnicastResponse: rawClass & DNSClass.topBit != 0
        )
    }

    mutating func record() throws(Failure) -> DNSRecord {
        let name = try name()
        let type = try uint16()
        let rawClass = try uint16()
        let ttl = try uint32()
        let length = Int(try uint16())
        guard index + length <= bytes.count else { throw .truncated }
        let end = index + length
        let data = try rdata(type: type, end: end)
        // `rdata` leaves the index at the start for the opaque types and past
        // the parsed fields for PTR and SRV, whose names are bounded only by
        // the packet. RFC 1035 §3.2.1 makes RDLENGTH the record's extent, so a
        // name must end exactly there; a pointer inside may still reach
        // anywhere earlier in the message.
        guard index == end || !Self.hasParsedRdata(type) else { throw .badLength }
        index = end
        return DNSRecord(
            name: name,
            data: data,
            ttl: ttl,
            cacheFlush: rawClass & DNSClass.topBit != 0,
            recordClass: rawClass & ~DNSClass.topBit
        )
    }

    private static func hasParsedRdata(_ type: UInt16) -> Bool {
        type == DNSType.ptr || type == DNSType.srv
    }

    private mutating func rdata(type: UInt16, end: Int) throws(Failure) -> DNSRecordData {
        let raw = Array(bytes[index..<end])
        switch type {
        case DNSType.addressV4 where raw.count == 4:
            return .ipv4(raw)
        case DNSType.addressV6 where raw.count == 16:
            return .ipv6(raw)
        case DNSType.ptr:
            return .ptr(try name())
        case DNSType.srv:
            let priority = try uint16()
            let weight = try uint16()
            let port = try uint16()
            return .srv(.init(priority: priority, weight: weight, port: port, target: try name()))
        case DNSType.txt:
            return .txt(raw)
        default:
            return .other(type: type, rdata: raw)
        }
    }

    /// Where a name being read has got to.
    private struct NameWalk {
        var cursor: Int
        /// Just past the first pointer, which is where the message continues.
        var resumeAt: Int?
        var total = 1
    }

    /// A name, following compression pointers backwards only.
    ///
    /// Backwards-only makes a chain of pointers strictly decreasing, and the
    /// 255-byte cap on a name (RFC 1035 §2.3.4) bounds a loop that reads labels
    /// between its pointers — so no packet can keep this reading for ever.
    mutating func name() throws(Failure) -> DNSName {
        var walk = NameWalk(cursor: index)
        var labels: [[UInt8]] = []
        while let label = try label(&walk) { labels.append(label) }
        index = walk.resumeAt ?? walk.cursor
        return DNSName(labels: labels)
    }

    /// The next label, following any pointers in front of it; nil at the root.
    private func label(_ walk: inout NameWalk) throws(Failure) -> [UInt8]? {
        while true {
            guard walk.cursor < bytes.count else { throw .truncated }
            let length = Int(bytes[walk.cursor])
            switch length & 0xC0 {
            case 0xC0:
                try follow(&walk, from: length)
            case 0:
                return try plainLabel(&walk, length: length)
            default:
                // 0x40 and 0x80 are RFC 6891's extended label types, which
                // Multicast DNS does not use.
                throw .badLabel
            }
        }
    }

    private func follow(_ walk: inout NameWalk, from length: Int) throws(Failure) {
        guard walk.cursor + 1 < bytes.count else { throw .truncated }
        let target = (length & 0x3F) << 8 | Int(bytes[walk.cursor + 1])
        guard target < walk.cursor else { throw .badPointer }
        if walk.resumeAt == nil { walk.resumeAt = walk.cursor + 2 }
        walk.cursor = target
    }

    private func plainLabel(_ walk: inout NameWalk, length: Int) throws(Failure) -> [UInt8]? {
        guard length > 0 else {
            walk.cursor += 1
            return nil
        }
        guard walk.cursor + 1 + length <= bytes.count else { throw .truncated }
        walk.total += 1 + length
        guard walk.total <= DNSName.maximumNameBytes else { throw .nameTooLong }
        defer { walk.cursor += 1 + length }
        return Array(bytes[(walk.cursor + 1)...(walk.cursor + length)])
    }

    private mutating func uint16() throws(Failure) -> UInt16 {
        guard index + 2 <= bytes.count else { throw .truncated }
        defer { index += 2 }
        return UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
    }

    private mutating func uint32() throws(Failure) -> UInt32 {
        UInt32(try uint16()) << 16 | UInt32(try uint16())
    }
}

import Foundation

/// Writes a ``DNSMessage`` in RFC 1035 §4.1 wire form.
///
/// **No name compression.** RFC 1035 §4.1.4 makes compression a thing a
/// sender *may* do, and every name this responder writes is short: its largest
/// message — a PTR answer with SRV, TXT, A and NSEC beside it — stays a few
/// hundred bytes under the 1500-byte Ethernet MTU RFC 6762 §17 asks a response
/// to fit in. The reader handles compression, because peers do use it.
struct DNSWriter {
    private(set) var bytes: [UInt8] = []

    static func encode(_ message: DNSMessage) -> [UInt8] {
        var writer = DNSWriter()
        writer.write(message)
        return writer.bytes
    }

    mutating func write(_ message: DNSMessage) {
        write(message.id)
        write(message.flags)
        write(UInt16(message.questions.count))
        write(UInt16(message.answers.count))
        write(UInt16(message.authorities.count))
        write(UInt16(message.additionals.count))
        for question in message.questions { write(question) }
        for record in message.allRecords { write(record) }
    }

    mutating func write(_ question: DNSQuestion) {
        write(question.name)
        write(question.type)
        write(question.recordClass | (question.wantsUnicastResponse ? DNSClass.topBit : 0))
    }

    mutating func write(_ record: DNSRecord) {
        write(record.name)
        write(record.data.type)
        write(record.recordClass | (record.cacheFlush ? DNSClass.topBit : 0))
        write(record.ttl)
        let rdata = Self.rdata(record.data)
        write(UInt16(rdata.count))
        bytes += rdata
    }

    /// RFC 1035 §3.1: each label length-prefixed, then the root's zero.
    mutating func write(_ name: DNSName) {
        for label in name.labels {
            bytes.append(UInt8(min(label.count, DNSName.maximumLabelBytes)))
            bytes += label.prefix(DNSName.maximumLabelBytes)
        }
        bytes.append(0)
    }

    mutating func write(_ value: UInt16) {
        bytes += [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    mutating func write(_ value: UInt32) {
        write(UInt16(value >> 16))
        write(UInt16(value & 0xFFFF))
    }

    static func rdata(_ data: DNSRecordData) -> [UInt8] {
        var writer = DNSWriter()
        switch data {
        case .ipv4(let address), .ipv6(let address):
            writer.bytes = address
        case .ptr(let name):
            writer.write(name)
        case .srv(let srv):
            // RFC 2782: priority, weight, port, target.
            writer.write(srv.priority)
            writer.write(srv.weight)
            writer.write(srv.port)
            writer.write(srv.target)
        case .txt(let text):
            // RFC 6763 §6.1: a TXT record may not be empty; a single zero byte
            // is the empty one.
            writer.bytes = text.isEmpty ? [0] : text
        case .nsec(let next, let types):
            writer.write(next)
            writer.bytes += nsecBitmap(types)
        case .other(_, let rdata):
            writer.bytes = rdata
        }
        return writer.bytes
    }

    /// RFC 4034 §4.1.2's type bitmap, restricted to window 0 as RFC 6762 §6.1
    /// requires: window number, bitmap length, then one bit per type with the
    /// most significant bit of the first byte meaning type 0.
    static func nsecBitmap(_ types: [UInt16]) -> [UInt8] {
        let inWindow = types.filter { $0 < 256 }
        guard let highest = inWindow.max() else { return [0, 1, 0] }
        var bitmap = [UInt8](repeating: 0, count: Int(highest) / 8 + 1)
        for type in inWindow {
            bitmap[Int(type) / 8] |= 0x80 >> (type % 8)
        }
        return [0, UInt8(bitmap.count)] + bitmap
    }
}

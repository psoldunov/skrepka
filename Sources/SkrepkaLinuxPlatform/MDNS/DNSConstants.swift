import Foundation

/// The record types this responder writes, and the one it asks with.
///
/// RFC 1035 §3.2.2 for A, PTR, TXT and ANY (`*`), RFC 3596 §2.1 for AAAA,
/// RFC 2782 for SRV, RFC 4034 §4 for NSEC.
enum DNSType {
    static let addressV4: UInt16 = 1
    static let ptr: UInt16 = 12
    static let txt: UInt16 = 16
    static let addressV6: UInt16 = 28
    static let srv: UInt16 = 33
    static let nsec: UInt16 = 47
    static let any: UInt16 = 255
}

/// RFC 1035 §3.2.4: IN, and the ANY class a question may ask for.
enum DNSClass {
    static let internet: UInt16 = 1
    static let any: UInt16 = 255
    /// RFC 6762 §18.12 and §18.13: the top bit of the class is not class. In a
    /// question it asks for a unicast response ("QU"); in a record it is the
    /// cache-flush bit, which marks the record unique.
    static let topBit: UInt16 = 0x8000
}

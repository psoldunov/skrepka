import Foundation

/// A record's typed RDATA.
enum DNSRecordData: Sendable, Hashable {
    /// Four octets.
    case ipv4([UInt8])
    /// Sixteen octets.
    case ipv6([UInt8])
    case ptr(DNSName)
    case srv(SRV)
    /// Wire-format TXT RDATA — RFC 6763 §6.1 length-prefixed strings, exactly
    /// `TXTRecord.dnsSDWireFormat`.
    case txt([UInt8])
    /// The restricted form RFC 6762 §6.1 requires every implementation to
    /// read: the record's own name, then window block 0 alone.
    case nsec(next: DNSName, types: [UInt16])
    case other(type: UInt16, rdata: [UInt8])

    struct SRV: Sendable, Hashable {
        let priority: UInt16
        let weight: UInt16
        let port: UInt16
        let target: DNSName
    }

    var type: UInt16 {
        switch self {
        case .ipv4: DNSType.addressV4
        case .ipv6: DNSType.addressV6
        case .ptr: DNSType.ptr
        case .srv: DNSType.srv
        case .txt: DNSType.txt
        case .nsec: DNSType.nsec
        case .other(let type, _): type
        }
    }

    /// Equality with names compared the way RFC 6762 §16 compares them.
    func isSame(as other: DNSRecordData) -> Bool {
        switch (self, other) {
        case (.ptr(let lhs), .ptr(let rhs)):
            lhs.matches(rhs)
        case (.srv(let lhs), .srv(let rhs)):
            lhs.priority == rhs.priority && lhs.weight == rhs.weight && lhs.port == rhs.port
                && lhs.target.matches(rhs.target)
        case (.nsec(let lhsNext, let lhsTypes), .nsec(let rhsNext, let rhsTypes)):
            lhsNext.matches(rhsNext) && Set(lhsTypes) == Set(rhsTypes)
        default:
            self == other
        }
    }
}

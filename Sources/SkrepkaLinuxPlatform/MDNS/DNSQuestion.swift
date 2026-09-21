import Foundation

/// One question.
struct DNSQuestion: Sendable, Hashable {
    let name: DNSName
    let type: UInt16
    let recordClass: UInt16
    /// RFC 6762 §5.4: the querier would accept a unicast reply.
    let wantsUnicastResponse: Bool

    init(
        name: DNSName,
        type: UInt16,
        recordClass: UInt16 = DNSClass.internet,
        wantsUnicastResponse: Bool = false
    ) {
        self.name = name
        self.type = type
        self.recordClass = recordClass
        self.wantsUnicastResponse = wantsUnicastResponse
    }

    /// RFC 6762 §6: the name matches, the type matches unless the question
    /// asked for ANY, and the class matches unless it asked for ANY.
    func isAnswered(by record: DNSRecord) -> Bool {
        guard record.name.matches(name) else { return false }
        guard type == DNSType.any || type == record.data.type else { return false }
        return recordClass == DNSClass.any || recordClass == record.recordClass
    }
}

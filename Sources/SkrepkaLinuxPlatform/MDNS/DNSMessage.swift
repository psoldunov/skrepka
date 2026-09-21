import Foundation

/// One DNS message, as Multicast DNS uses it.
///
/// RFC 1035 §4.1's layout with RFC 6762 §18's readings of the header: the ID
/// is zero on anything multicast (§18.1) and echoed only in a legacy unicast
/// reply (§6.7); a response sets QR and AA (§18.2, §18.4); every other header
/// bit is zero on send and ignored on receipt.
struct DNSMessage: Sendable, Hashable {
    /// QR (§18.2) and AA (§18.4): "Multicast DNS responses MUST set the AA bit".
    static let responseFlags: UInt16 = 0x8400
    static let queryFlags: UInt16 = 0

    let id: UInt16
    let flags: UInt16
    let questions: [DNSQuestion]
    let answers: [DNSRecord]
    let authorities: [DNSRecord]
    let additionals: [DNSRecord]

    init(
        id: UInt16 = 0,
        flags: UInt16,
        questions: [DNSQuestion] = [],
        answers: [DNSRecord] = [],
        authorities: [DNSRecord] = [],
        additionals: [DNSRecord] = []
    ) {
        self.id = id
        self.flags = flags
        self.questions = questions
        self.answers = answers
        self.authorities = authorities
        self.additionals = additionals
    }

    /// QR, the top bit of the flags.
    var isResponse: Bool { flags & 0x8000 != 0 }

    /// RFC 6762 §18.3: a message with a non-zero OPCODE "MUST be silently
    /// ignored".
    var hasStandardOpcode: Bool { (flags >> 11) & 0x0F == 0 }

    /// Every record a response carries. RFC 6762 §9 looks for conflicts in all
    /// of them, not only in the answers.
    var allRecords: [DNSRecord] { answers + authorities + additionals }
}

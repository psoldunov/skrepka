import Foundation

/// Whether a response received from the link says another host holds one of
/// the names this one claims.
///
/// **What is implemented.** RFC 6762 §8.1 while probing — any record with a
/// claimed name, of any type, that is not identical to one of this host's —
/// and §9 once established: a record with a claimed name, type and class and
/// different rdata. Either way the answer is to rename and start again; both
/// names are this device's (see ``MDNSNaming``), so a conflict means a
/// genuinely different machine, and deferring is always right.
///
/// **Deliberately not implemented:** §8.2's simultaneous-probe tiebreak: two hosts probing the
/// same name in the same 750 ms each see only the other's *query*, and this
/// responder does not compare the proposed records in it — both would go on
/// to announce and then find each other by §9, one step later than the RFC
/// intends. The names involved make that a near-impossibility: an instance
/// name is also shared only by two devices with the same display name probing
/// at once, and the host name carries the device identifier.
enum MDNSConflict {
    /// - Parameters:
    ///   - records: this host's records, carrying **every** address it owns on
    ///     any interface. Two interfaces on one link hear each other's
    ///     announcements, and an A record for this host's name with the other
    ///     interface's address is this host, not a rival.
    ///   - probing: whether the §8.1 rule applies rather than the §9 one.
    static func isConflicting(
        _ response: DNSMessage,
        with records: MDNSServiceRecords,
        probing: Bool
    ) -> Bool {
        guard response.isResponse, response.hasStandardOpcode else { return false }
        let owned = records.uniqueRecords
        let claimed = [records.instanceName, records.hostName]
        return response.allRecords.contains { received in
            // A goodbye withdraws a record; it claims nothing.
            guard received.ttl > 0, claimed.contains(where: { $0.matches(received.name) }) else {
                return false
            }
            if owned.contains(where: { $0.isSameRecord(as: received) }) { return false }
            if probing { return true }
            return owned.contains {
                $0.name.matches(received.name) && $0.data.type == received.data.type
                    && $0.recordClass == received.recordClass
            }
        }
    }
}

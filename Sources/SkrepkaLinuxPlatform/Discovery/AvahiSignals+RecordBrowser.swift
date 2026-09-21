import DBUS
import Foundation
import SkrepkaSync

// MARK: - Record browser signals

extension AvahiSignals {
    /// One `ItemNew` or `ItemRemove` from a `RecordBrowser`:
    /// `(i interface, i protocol, s name, q clazz, q type, ay rdata, u flags)`.
    struct RecordItem: Sendable, Hashable {
        let interfaceIndex: Int32
        let networkProtocol: Int32
        let name: String
        let recordClass: UInt16
        let recordType: UInt16
        /// Wire-format RDATA. For a TXT record, RFC 6763 §6.1 length-prefixed
        /// strings — what `TXTRecord(dnsSDWireFormat:)` reads.
        let rdata: [UInt8]
        let flags: UInt32

        /// The peer's advertisement, read from this TXT record.
        ///
        /// Throws the same ``SkrepkaSync/AdvertisementError`` a resolve would,
        /// so a record this build cannot read is reported the way the resolve
        /// path reports one.
        func advertisement() throws -> PeerAdvertisement {
            try PeerAdvertisement(dnsSDWireFormat: Data(rdata))
        }
    }

    static func recordItem(_ body: [DBusValue]) -> RecordItem? {
        guard body.count >= 7,
            case .int32(let interfaceIndex) = body[0],
            case .int32(let networkProtocol) = body[1],
            case .string(let name) = body[2],
            case .uint16(let recordClass) = body[3],
            case .uint16(let recordType) = body[4],
            let rdata = bytes(body[5]),
            case .uint32(let flags) = body[6]
        else { return nil }
        return RecordItem(
            interfaceIndex: interfaceIndex,
            networkProtocol: networkProtocol,
            name: name,
            recordClass: recordClass,
            recordType: recordType,
            rdata: rdata,
            flags: flags
        )
    }

    /// One `ay`.
    static func bytes(_ value: DBusValue) -> [UInt8]? {
        guard case .array(let elements) = value else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(elements.count)
        for element in elements {
            guard case .byte(let byte) = element else { return nil }
            bytes.append(byte)
        }
        return bytes
    }
}

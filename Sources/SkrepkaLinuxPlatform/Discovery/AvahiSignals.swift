import DBUS
import Foundation
import SkrepkaSync

/// Reading avahi's signal bodies, as pure functions.
///
/// Separated from the actor that receives them for one reason: **this is the
/// part that can be tested without a daemon.** The phase plan asks for
/// `AvahiDiscoveryTests.parsesServiceRecords` "against captured D-Bus payloads,
/// no live daemon", and a decoder folded into a `for await` over a live
/// connection is one nothing can drive. Every function here takes a `[DBusValue]`
/// body — exactly what a captured message carries — and returns a value or nil.
///
/// Nil rather than a throw throughout. A signal whose body does not match the
/// documented signature is a daemon this build cannot talk to, and the only
/// useful response is to ignore that one message; there is no caller who could
/// act on a typed error, and turning every malformed broadcast into a thrown
/// error would end a browse that is otherwise working.
enum AvahiSignals {
    /// One `ItemNew` or `ItemRemove`.
    struct BrowseItem: Sendable, Hashable {
        let interfaceIndex: Int32
        let networkProtocol: Int32
        let name: String
        let serviceType: String
        let domain: String
        let flags: UInt32

        /// The browse result, with no advertisement.
        ///
        /// **Always `.unread`.** Avahi's browse signals carry no TXT record at
        /// all — the record arrives only from a `ServiceResolver` — which is
        /// precisely why ``SkrepkaSync/DiscoveredPeer/AdvertisementState`` has
        /// an `unread` case rather than an optional advertisement.
        var peer: DiscoveredPeer {
            DiscoveredPeer(
                instanceName: name,
                serviceType: serviceType,
                domain: domain,
                // `AVAHI_IF_UNSPEC` is -1 and means "any", which the protocol
                // spells as nil rather than as a number one conformance has to
                // know the other's magic value for.
                interfaceIndex: interfaceIndex >= 0 ? UInt32(interfaceIndex) : nil,
                advertisement: .unread
            )
        }
    }

    /// One `Found` from a `ServiceResolver`.
    struct Resolution: Sendable, Hashable {
        let name: String
        let serviceType: String
        let domain: String
        /// The SRV target — a host *name*, usually `something.local`. Left as a
        /// name deliberately: turning it into an address here would pin one of
        /// the peer's addresses and keep using it after the peer moved network.
        let host: String
        let address: String
        let port: UInt16
        /// Raw `key=value` byte arrays, exactly as they came off the wire.
        let txt: [[UInt8]]
    }

    static func browseItem(_ body: [DBusValue]) -> BrowseItem? {
        guard body.count >= 6,
            case .int32(let interfaceIndex) = body[0],
            case .int32(let networkProtocol) = body[1],
            case .string(let name) = body[2],
            case .string(let serviceType) = body[3],
            case .string(let domain) = body[4],
            case .uint32(let flags) = body[5]
        else { return nil }
        return BrowseItem(
            interfaceIndex: interfaceIndex,
            networkProtocol: networkProtocol,
            name: name,
            serviceType: serviceType,
            domain: domain,
            flags: flags
        )
    }

    static func resolution(_ body: [DBusValue]) -> Resolution? {
        guard body.count >= 11,
            case .string(let name) = body[2],
            case .string(let serviceType) = body[3],
            case .string(let domain) = body[4],
            case .string(let host) = body[5],
            case .string(let address) = body[7],
            case .uint16(let port) = body[8],
            let txt = byteArrays(body[9])
        else { return nil }
        return Resolution(
            name: name,
            serviceType: serviceType,
            domain: domain,
            host: host,
            address: address,
            port: port,
            txt: txt
        )
    }

    /// `(i state, s error)` from an entry group.
    static func entryGroupState(_ body: [DBusValue]) -> (AvahiNames.EntryGroupState, String)? {
        guard body.count >= 2,
            case .int32(let raw) = body[0],
            case .string(let error) = body[1],
            let state = AvahiNames.EntryGroupState(rawValue: raw)
        else { return nil }
        return (state, error)
    }

    /// `(i state, s error)` from the daemon itself.
    ///
    /// The same body shape as an entry group's, and deliberately not the same
    /// function: the two states are separate enumerations in `defs.h`, and
    /// decoding one as the other would read `AVAHI_SERVER_COLLISION` as an entry
    /// group that lost its name.
    static func serverState(_ body: [DBusValue]) -> (AvahiNames.ServerState, String)? {
        guard body.count >= 2,
            case .int32(let raw) = body[0],
            case .string(let error) = body[1],
            let state = AvahiNames.ServerState(rawValue: raw)
        else { return nil }
        return (state, error)
    }

    /// The single string a `Failure` signal carries.
    static func failureReason(_ body: [DBusValue]) -> String? {
        guard case .string(let reason) = body.first else { return nil }
        return reason
    }

    // MARK: - TXT records

    /// Turns avahi's `aay` into the ordered byte pairs Skrepka's record type
    /// holds.
    ///
    /// The bytes are `key=value` with **no length prefix**, which is the whole
    /// difference from the DNS-SD wire form: RFC 6763 §6.1 length-prefixes each
    /// entry and avahi has already stripped that.
    static func byteArrays(_ value: DBusValue) -> [[UInt8]]? {
        guard case .array(let entries) = value else { return nil }
        var records: [[UInt8]] = []
        records.reserveCapacity(entries.count)
        for entry in entries {
            guard case .array(let bytes) = entry else { return nil }
            var raw: [UInt8] = []
            raw.reserveCapacity(bytes.count)
            for byte in bytes {
                guard case .byte(let value) = byte else { return nil }
                raw.append(value)
            }
            records.append(raw)
        }
        return records
    }

    /// A record to advertise, as the `aay` `AddService` and `UpdateServiceTxt`
    /// take.
    ///
    /// `TXTRecord.avahiEntries` is the encoding — Phase 1 put it there for
    /// exactly this caller, alongside `dnsSDWireFormat` for the Bonjour one, so
    /// that neither backend hand-rolls the record's byte layout.
    static func txtArgument(_ record: TXTRecord) -> DBusValue {
        .array(
            record.avahiEntries.map { entry in
                .array(entry.map { DBusValue.byte($0) })
            })
    }
}

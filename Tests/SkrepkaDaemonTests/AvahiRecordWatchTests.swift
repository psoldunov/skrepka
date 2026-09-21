import DBUS
import Foundation
import SkrepkaSync
import Testing

@testable import SkrepkaLinuxPlatform

/// Following a peer's TXT record through avahi's `RecordBrowser`, against
/// hand-built signal bodies and no live daemon.
///
/// The bodies are the `ItemNew` signature from
/// `org.freedesktop.Avahi.RecordBrowser.xml` — `(i, i, s, q, q, ay, u)` — with
/// the rdata a Mac's `DNSServiceUpdateRecord` produces: RFC 6763 §6.1
/// length-prefixed strings.
@Suite("Avahi TXT record watch")
struct AvahiRecordWatchTests {
    static let macID = String(repeating: "d", count: 64)

    static func rdata(pairingPort: UInt16?) throws -> [UInt8] {
        let descriptor = ServiceDescriptor(
            displayName: "Philipp's Mac",
            port: 7011,
            deviceID: try #require(SyncDeviceID(hex: macID)),
            platform: .macos,
            pairingPort: pairingPort
        )
        return Array(try descriptor.txtRecord().dnsSDWireFormat)
    }

    static func itemBody(_ rdata: [UInt8], type: UInt16 = 16) -> [DBusValue] {
        [
            .int32(3), .int32(0), .string("Philipp\\039s\\032Mac._skrepka._tcp.local"),
            .uint16(1), .uint16(type), .array(rdata.map { DBusValue.byte($0) }), .uint32(0),
        ]
    }

    static let peer = DiscoveredPeer(
        instanceName: "Philipp's Mac",
        serviceType: "_skrepka._tcp",
        domain: "local",
        interfaceIndex: 3,
        advertisement: .unread
    )

    @Test("a record browser's ItemNew decodes to its raw rdata")
    func decodesRecordItems() throws {
        let rdata = try Self.rdata(pairingPort: 50505)
        let item = try #require(AvahiSignals.recordItem(Self.itemBody(rdata)))
        #expect(item.recordClass == 1)
        #expect(item.recordType == 16)
        #expect(item.rdata == rdata)
        #expect(try item.advertisement().pairingPort == 50505)
    }

    @Test("a body of the wrong shape is ignored rather than thrown")
    func refusesMalformedItems() {
        #expect(AvahiSignals.recordItem([.int32(0)]) == nil)
        var body = Self.itemBody([1, 2])
        body[5] = .string("not bytes")
        #expect(AvahiSignals.recordItem(body) == nil)
    }

    @Test("the pairing window opening in place is reported as a change")
    func reportsAPairingWindowOpening() throws {
        let closed = try Self.rdata(pairingPort: nil)
        let open = try Self.rdata(pairingPort: 50505)
        let (first, seen) = PeerRecordWatch(peer: Self.peer).arriving(closed)
        guard case .changed(let before) = seen else {
            Issue.record("the first record is news")
            return
        }
        #expect(before.isAcceptingPairing == false)

        // avahi's cache reports an update as ItemNew for the new rdata, then
        // ItemRemove for the old one a second later.
        let (second, update) = first.arriving(open)
        guard case .changed(let after) = update else {
            Issue.record("a rewritten record is a change")
            return
        }
        #expect(after.pairingPort == 50505)
        let settled = second.leaving(closed)
        #expect(settled.current == open)
        #expect(settled.changedPeer(after).advertisement == .read(after))
        #expect(settled.changedPeer(after).instanceName == "Philipp's Mac")
    }

    @Test("the same record twice is not news")
    func ignoresRepeats() throws {
        let open = try Self.rdata(pairingPort: 50505)
        let (watch, _) = PeerRecordWatch(peer: Self.peer).arriving(open)
        #expect(watch.arriving(open).outcome == .unchanged)
        // Expired and replayed — after an avahi cache flush — is the same
        // advertisement, so still not reported.
        let replayed = watch.leaving(open).arriving(open)
        #expect(replayed.outcome == .unchanged)
    }

    @Test("an ItemRemove for a record that is not current changes nothing")
    func ignoresStaleRemovals() throws {
        let open = try Self.rdata(pairingPort: 50505)
        let (watch, _) = PeerRecordWatch(peer: Self.peer).arriving(open)
        #expect(watch.leaving([0x05, 0x61]) == watch)
    }

    @Test("an unreadable record is reported as such, not as a change")
    func reportsUnreadableRecords() {
        let broken: [UInt8] = [0x09] + Array("txtvers=1".utf8) + [0x03] + Array("x=1".utf8)
        let (watch, outcome) = PeerRecordWatch(peer: Self.peer).arriving(broken)
        guard case .unreadable = outcome else {
            Issue.record("a record with no id= is unreadable")
            return
        }
        #expect(watch.reported == nil)
    }

    @Test("an instance name is escaped the way avahi_escape_label does it")
    func escapesInstanceNames() {
        #expect(
            AvahiNames.serviceRecordName(
                instance: "Philipp's Mac", serviceType: "_skrepka._tcp", domain: "local")
                == "Philipp\\039s\\032Mac._skrepka._tcp.local")
        #expect(AvahiNames.escapedLabel("a.b\\c") == "a\\.b\\\\c")
        #expect(AvahiNames.escapedLabel("steamdeck #2") == "steamdeck\\032\\0352")
        // Each byte of a non-ASCII character is escaped on its own.
        #expect(AvahiNames.escapedLabel("é") == "\\195\\169")
        #expect(
            AvahiNames.serviceRecordName(instance: "x", serviceType: "_s._tcp", domain: "")
                == "x._s._tcp.local")
    }
}

import DBUS
import Foundation
import SkrepkaSync
import Testing

@testable import SkrepkaLinuxPlatform

/// Reading avahi's signal bodies, against captured payloads and no live daemon.
///
/// The bodies below are what `org.freedesktop.Avahi` actually sends, built from
/// the argument lists in its own interface definitions — `ItemNew` is
/// `(i, i, s, s, s, u)` and `Found` is `(i, i, s, s, s, s, i, s, q, aay, u)`.
/// Written as `DBusValue` arrays rather than as encoded bytes because that is
/// the boundary `AvahiSignals` is defined at: the library owns turning wire
/// bytes into values, and everything Skrepka decides starts here.
@Suite("Avahi signal decoding")
struct AvahiSignalsTests {
    static func txtEntry(_ text: String) -> DBusValue {
        .array(Array(text.utf8).map { DBusValue.byte($0) })
    }

    @Test("a browse result becomes a peer with no advertisement")
    func parsesBrowseResults() throws {
        let body: [DBusValue] = [
            .int32(2),
            .int32(0),
            .string("kavallaris"),
            .string("_skrepka._tcp"),
            .string("local"),
            .uint32(0),
        ]
        let item = try #require(AvahiSignals.browseItem(body))
        #expect(item.name == "kavallaris")
        #expect(item.serviceType == "_skrepka._tcp")
        #expect(item.domain == "local")
        #expect(item.interfaceIndex == 2)

        let peer = item.peer
        #expect(peer.instanceName == "kavallaris")
        #expect(peer.interfaceIndex == 2)
        // Avahi's browse signals carry no TXT record at all, which is the whole
        // reason `AdvertisementState` has an `unread` case.
        #expect(peer.advertisement == .unread)
    }

    @Test("AVAHI_IF_UNSPEC becomes nil rather than a magic number")
    func unspecifiedInterfaceIsNil() throws {
        let body: [DBusValue] = [
            .int32(-1), .int32(-1), .string("peer"), .string("_skrepka._tcp"),
            .string("local"), .uint32(0),
        ]
        let item = try #require(AvahiSignals.browseItem(body))
        // dns_sd spells "any interface" as 0 and avahi spells it -1. The
        // protocol carries neither.
        #expect(item.peer.interfaceIndex == nil)
    }

    @Test("a body of the wrong shape is ignored rather than thrown")
    func refusesAMalformedBrowseResult() {
        #expect(AvahiSignals.browseItem([.string("wrong"), .int32(0)]) == nil)
        #expect(AvahiSignals.browseItem([]) == nil)
    }

    @Test("a resolution carries the host, the port and the raw TXT record")
    func parsesServiceRecords() throws {
        let body: [DBusValue] = [
            .int32(2),
            .int32(0),
            .string("kavallaris"),
            .string("_skrepka._tcp"),
            .string("local"),
            .string("kavallaris.local"),
            .int32(0),
            .string("192.168.1.42"),
            .uint16(7011),
            .array([
                Self.txtEntry("txtvers=1"),
                Self.txtEntry("id=" + String(repeating: "a", count: 64)),
                Self.txtEntry("name=kavallaris"),
                Self.txtEntry("proto=1"),
                Self.txtEntry("plat=linux"),
            ]),
            .uint32(0),
        ]
        let resolution = try #require(AvahiSignals.resolution(body))
        #expect(resolution.host == "kavallaris.local")
        #expect(resolution.port == 7011)
        #expect(resolution.txt.count == 5)

        // The bytes are `key=value` with no length prefix — the whole
        // difference from the DNS-SD wire form, which length-prefixes each
        // entry. `TXTRecord(avahiEntries:)` is what knows that.
        let record = try TXTRecord(avahiEntries: resolution.txt)
        let advertisement = try PeerAdvertisement(txtRecord: record)
        #expect(advertisement.displayName == "kavallaris")
        #expect(advertisement.platform == .linux)
        #expect(advertisement.deviceID.hex == String(repeating: "a", count: 64))
        // No `pair=` key means the peer is not accepting pairings, which is a
        // fact rather than a gap.
        #expect(advertisement.isAcceptingPairing == false)
    }

    @Test("a pairing port in the record survives the round trip")
    func readsThePairingPort() throws {
        let entries = [
            "txtvers=1", "id=" + String(repeating: "b", count: 64),
            "proto=1", "plat=linux", "pair=54321",
        ]
        let record = try TXTRecord(avahiEntries: entries.map { Array($0.utf8) })
        let advertisement = try PeerAdvertisement(txtRecord: record)
        #expect(advertisement.pairingPort == 54321)
        #expect(advertisement.isAcceptingPairing)
    }

    @Test("a record this build writes encodes as avahi's aay")
    func encodesTheRecordAvahiWants() throws {
        let descriptor = ServiceDescriptor(
            displayName: "kavallaris",
            port: 7011,
            deviceID: try #require(SyncDeviceID(hex: String(repeating: "c", count: 64))),
            platform: .linux,
            pairingPort: 40404
        )
        let argument = AvahiSignals.txtArgument(try descriptor.txtRecord())
        guard case .array(let entries) = argument else {
            Issue.record("the TXT argument must be an array")
            return
        }
        // Every element is itself an array of bytes — `aay`, not `as`. A record
        // encoded as an array of strings is accepted by nothing.
        let decoded = try #require(AvahiSignals.byteArrays(argument))
        #expect(decoded.count == entries.count)
        let text = decoded.compactMap { String(bytes: $0, encoding: .utf8) }
        #expect(text.contains("txtvers=1"))
        #expect(text.contains("plat=linux"))
        #expect(text.contains("pair=40404"))
        // Round-trips through the reader, which is the property that matters:
        // what this device advertises is what a peer running this code reads.
        let advertisement = try PeerAdvertisement(txtRecord: TXTRecord(avahiEntries: decoded))
        #expect(advertisement.deviceID == descriptor.deviceID)
        #expect(advertisement.pairingPort == 40404)
    }

    @Test("an entry group's state and its error come back together")
    func parsesEntryGroupState() throws {
        let established = try #require(
            AvahiSignals.entryGroupState([.int32(2), .string("")]))
        #expect(established.0 == .established)

        let collision = try #require(
            AvahiSignals.entryGroupState([.int32(3), .string("Local name collision")]))
        #expect(collision.0 == .collision)
        #expect(collision.1 == "Local name collision")

        // A state number this build has never heard of is refused rather than
        // read as one it knows.
        #expect(AvahiSignals.entryGroupState([.int32(99), .string("")]) == nil)
    }

    @Test("a failure signal's reason is read")
    func parsesFailure() {
        #expect(AvahiSignals.failureReason([.string("Timeout reached")]) == "Timeout reached")
        #expect(AvahiSignals.failureReason([.int32(0)]) == nil)
    }

    /// `AVAHI_SERVER_RUNNING` is 2 and so is `AVAHI_ENTRY_GROUP_ESTABLISHED`,
    /// which is exactly why these are two decoders: the bodies are identical on
    /// the wire and the meanings are not. A restart that arrived as
    /// "established" would look like a publish nobody asked for.
    @Test("the daemon's own state decodes separately from an entry group's")
    func parsesServerState() throws {
        let running = try #require(AvahiSignals.serverState([.int32(2), .string("")]))
        #expect(running.0 == .running)

        let collision = try #require(
            AvahiSignals.serverState([.int32(3), .string("Host name conflict")]))
        #expect(collision.0 == .collision)
        #expect(collision.1 == "Host name conflict")

        #expect(AvahiSignals.serverState([.int32(99), .string("")]) == nil)
        #expect(AvahiSignals.serverState([.int32(2)]) == nil)
    }

    /// The conversion the D-Bus client's `timeoutNanoseconds:` needs, which
    /// takes a `UInt64` where everything above it is a `Duration`.
    @Test("a duration converts to whole nanoseconds without trapping")
    func convertsDurationsToNanoseconds() {
        #expect(Duration.seconds(2).wholeNanoseconds == 2_000_000_000)
        #expect(Duration.milliseconds(1500).wholeNanoseconds == 1_500_000_000)
        #expect(Duration.zero.wholeNanoseconds == 0)
        // A deadline in the past is a deadline of nothing, not a crash and not
        // an enormous unsigned number read from a negative one.
        #expect(Duration.seconds(-5).wholeNanoseconds == 0)
    }
}

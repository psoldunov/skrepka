#if canImport(Network)

    import Foundation
    import Network
    import Testing

    @testable import SkrepkaSync

    /// The one part of ``BonjourDiscovery`` that can be tested without a
    /// network: that the bytes this build produces are the bytes Apple's own
    /// parser reads back, and the reverse.
    ///
    /// Everything else in that type needs a live `mDNSResponder`, a real
    /// multicast interface, and on macOS 15 and later a Local Network
    /// permission grant attributed to whichever process launched the test
    /// binary. A test that registers a real service would pass on a developer's
    /// machine and fail in CI for reasons unrelated to the code, and the repo's
    /// conventions say not to write it. What is verified by hand instead is
    /// recorded in the pull request.
    @Suite("Bonjour TXT record interoperability")
    struct BonjourTXTRecordTests {
        /// `DNSServiceRegister` takes exactly these bytes, and
        /// `NWBrowser.Result.Metadata.bonjour` hands back an `NWTXTRecord`
        /// parsed from them. If the two disagree the browser reports a peer
        /// whose record is empty, which looks identical to a peer that
        /// advertised nothing.
        @Test("Bonjour reads back the record this build writes")
        func bonjourReadsOurWireFormat() throws {
            let descriptor = ServiceDescriptor(
                displayName: "Работа",
                port: 7011,
                deviceID: SyncFixtures.deviceA,
                platform: .macos
            )
            let record = try descriptor.txtRecord()

            let parsed = NWTXTRecord(record.dnsSDWireFormat)
            #expect(parsed["txtvers"] == "1")
            #expect(parsed["id"] == SyncFixtures.deviceA.hex)
            #expect(parsed["name"] == "Работа")
            #expect(parsed["proto"] == "1")
            #expect(parsed["plat"] == "macos")
            #expect(parsed["fp"] == nil)
        }

        /// The other direction: what `NWTXTRecord` emits has to read as an
        /// advertisement, because that is the path a browse result takes.
        @Test("This build reads back the record Bonjour writes")
        func weReadBonjoursWireFormat() throws {
            let bonjour = NWTXTRecord([
                "txtvers": "1",
                "id": SyncFixtures.deviceB.hex,
                "name": "desktop",
                "proto": "1",
                "plat": "linux",
            ])

            let advertisement = try PeerAdvertisement(dnsSDWireFormat: bonjour.data)
            #expect(advertisement.deviceID == SyncFixtures.deviceB)
            #expect(advertisement.displayName == "desktop")
            #expect(advertisement.platform == .linux)
            #expect(advertisement.protocolVersion == .current)
        }

        /// A key present with no `=` at all — `NWTXTRecord.Entry.none` against
        /// `.empty` — is the distinction most easily lost in a round trip, and
        /// the one the advertisement reader depends on to tell "advertised
        /// nothing" from "advertised an empty name".
        @Test("A valueless attribute survives a round trip through Bonjour")
        func valuelessAttributeSurvives() throws {
            let record = try TXTRecord([
                TXTRecord.Entry(key: "flag", value: nil),
                TXTRecord.Entry(key: "empty", value: ""),
            ])

            // Bonjour's names for the same three shapes, confirmed against a
            // live `NWTXTRecord`: `key` alone is `.none`, `key=` is `.empty`,
            // and a key that was never advertised has no entry at all.
            let parsed = NWTXTRecord(record.dnsSDWireFormat)
            #expect(parsed.getEntry(for: "flag") == NWTXTRecord.Entry.none)
            #expect(parsed.getEntry(for: "empty") == .empty)
            #expect(parsed.getEntry(for: "absent") == nil)
            #expect(parsed.data == record.dnsSDWireFormat)

            let decoded = try TXTRecord(dnsSDWireFormat: parsed.data)
            #expect(decoded.entry(for: "flag")?.value == nil)
            #expect(decoded.entry(for: "empty")?.value?.isEmpty == true)
        }
    }

#endif

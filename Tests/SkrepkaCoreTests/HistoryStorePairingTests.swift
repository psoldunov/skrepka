// The SwiftData store's own mappings. What the two engines share — pairing,
// the anti-downgrade mark, the sync surface — is asserted in
// `HistoryStoringTests` against every conformance, and duplicating it here would
// mean a behaviour change showing up as two failures on macOS and one on Linux.
//
// These four are not shared. `SyncMetaMapping` converts a `ClipRecord` to and
// from the wire type and `RepresentationIndex` encodes the denormalised column
// that goes with it; the SQLite store has neither type and no column for one, so
// this is the only place either can be exercised.
#if canImport(SwiftData)

    import Foundation
    import SkrepkaSync
    import Testing

    @testable import SkrepkaCore

    @Suite("History store mapping")
    @MainActor
    struct HistoryStorePairingTests {
        @Test("A record survives a round trip through SyncMetaMapping")
        func syncMetaMappingRoundTrips() throws {
            let original = SyncFixtures.meta("round trip", pinned: true)
            let record = try SyncMetaMapping.makeRecord(from: original)
            let restored = SyncMetaMapping.meta(
                from: record,
                representations: try RepresentationIndex.decode(
                    try #require(record.representationIndex)
                ),
                localDeviceID: SyncFixtures.localDevice
            )

            #expect(restored == original)
            // Payload bytes are not part of the trip. Metadata is eager and payload
            // is lazy (design §7), so a row learned from a peer carries none until
            // the transport fetches them.
            #expect(record.payloadData.isEmpty)
        }

        @Test("A row that names no device is described as this one's")
        func mappingSubstitutesTheLocalDeviceForARowWithNoOrigin() throws {
            let record = try SyncMetaMapping.makeRecord(from: SyncFixtures.meta("legacy"))
            record.originDeviceID = nil
            record.pinnedBy = nil
            record.pinnedAt = nil

            let meta = SyncMetaMapping.meta(
                from: record,
                representations: [:],
                localDeviceID: SyncFixtures.localDevice
            )
            #expect(meta.originDeviceID == SyncFixtures.localDevice)
            #expect(meta.isPinned.deviceID == SyncFixtures.localDevice)
            // A row pinned before the register existed falls back to createdAt
            // rather than to the clock, so building the index twice gives the same
            // answer.
            #expect(meta.isPinned.timestamp == record.createdAt)
        }

        @Test("A representation with no canonical media type is dropped, not invented")
        func unmappableRepresentationsAreDropped() {
            // `com.apple.flat-rtfd` maps to nothing: it is an Apple bundle that has
            // to be flattened rather than renamed. Offering it under a made-up
            // media type would have a peer fetch bytes it cannot read.
            let descriptors = SyncMetaMapping.descriptors(
                from: [PasteboardType.rtfd: 99, PasteboardType.string: 5]
            )
            #expect(descriptors == [SyncFixtures.plainTextDescriptor(byteCount: 5)])
        }

        @Test("An empty representation index encodes and decodes as empty")
        func representationIndexHandlesEmptyData() throws {
            #expect(try RepresentationIndex.decode(Data()).isEmpty)
            #expect(try RepresentationIndex.decode(RepresentationIndex.encode([:])).isEmpty)
        }
    }

#endif

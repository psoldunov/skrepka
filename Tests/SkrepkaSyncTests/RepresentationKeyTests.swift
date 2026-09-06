import Foundation
import Testing

@testable import SkrepkaSync

/// Design §8's table, in both directions.
@Suite("Representation keys")
struct RepresentationKeyTests {
    @Test("Every UTI round-trips through its canonical media type")
    func utiRoundTripsThroughCanonical() {
        #expect(!RepresentationKeyMap.entries.isEmpty)
        for entry in RepresentationKeyMap.entries {
            #expect(RepresentationKeyMap.canonical(forUTI: entry.uti) == entry.canonical)
            #expect(RepresentationKeyMap.uti(forCanonical: entry.canonical) == entry.uti)
        }
    }

    @Test("Every Linux target round-trips through its canonical media type")
    func linuxTargetRoundTripsThroughCanonical() throws {
        for entry in RepresentationKeyMap.entries {
            for target in entry.linuxTargets {
                #expect(RepresentationKeyMap.canonical(forLinuxTarget: target) == entry.canonical)
            }
            let primary = try #require(RepresentationKeyMap.linuxTarget(forCanonical: entry.canonical))
            #expect(entry.linuxTargets.first == primary)
        }
    }

    /// A map with two rows claiming one canonical key, or one UTI, would make
    /// the round trip above pass while the mapping was still ambiguous.
    @Test("No canonical key, UTI or Linux target appears twice")
    func mapsAreUnambiguous() {
        let entries = RepresentationKeyMap.entries
        #expect(Set(entries.map(\.canonical)).count == entries.count)
        #expect(Set(entries.map(\.uti)).count == entries.count)
        let targets = entries.flatMap(\.linuxTargets)
        #expect(Set(targets).count == targets.count)
    }

    /// The lossy case, explicit rather than a silent nil. RTFD is an Apple
    /// bundle — RTF plus embedded attachments — and flattening it to HTML plus
    /// PNG is a transformation, which belongs in Phase 3 and not in a lookup
    /// table.
    @Test("RTFD has no canonical form, and the map says so")
    func rtfdHasNoCanonicalForm() {
        let rtfd = "com.apple.flat-rtfd"
        #expect(RepresentationKeyMap.canonical(forUTI: rtfd) == nil)
        #expect(RepresentationKeyMap.key(forUTI: rtfd) == nil)
        #expect(RepresentationKeyMap.unmappableUTIs[rtfd] != nil)
        #expect(!RepresentationKeyMap.entries.contains { $0.uti == rtfd })
    }

    /// The origin key is opaque passthrough: it rides along so a Mac↔Mac round
    /// trip stays lossless, and is ignored by anyone else.
    @Test("A key built from a platform type keeps that type as its origin")
    func keysCarryTheirOriginKey() throws {
        let fromUTI = try #require(RepresentationKeyMap.key(forUTI: "public.png"))
        #expect(fromUTI == RepresentationKey(canonical: "image/png", origin: "public.png"))

        let fromLinux = try #require(RepresentationKeyMap.key(forLinuxTarget: "text/plain"))
        #expect(fromLinux.canonical == "text/plain;charset=utf-8")
        #expect(fromLinux.origin == "text/plain")
    }

    @Test("An unmapped type is nil in every direction")
    func unmappedTypesAreNil() {
        #expect(RepresentationKeyMap.canonical(forUTI: "com.example.nonsense") == nil)
        #expect(RepresentationKeyMap.uti(forCanonical: "application/x-nonsense") == nil)
        #expect(RepresentationKeyMap.canonical(forLinuxTarget: "x-special/nonsense") == nil)
        // `public.url` deliberately has no row: design §8 gives it none, and
        // mapping it to `text/uri-list` would collide with `public.file-url`.
        #expect(RepresentationKeyMap.canonical(forUTI: "public.url") == nil)
    }
}

import Foundation
import SkrepkaCore
import SkrepkaSync
import Testing

@testable import SkrepkaLinuxPlatform

@Suite("Linux representation mapping")
struct LinuxRepresentationMapTests {
    @Test(
        "MIME targets map to the identifiers the capture pipeline speaks",
        arguments: [
            ("text/plain;charset=utf-8", PasteboardType.string),
            ("text/plain", PasteboardType.string),
            ("text/html", PasteboardType.html),
            ("image/png", PasteboardType.png),
            ("image/tiff", PasteboardType.tiff),
            ("image/jpeg", PasteboardType.jpeg),
            ("application/pdf", PasteboardType.pdf),
            ("text/rtf", PasteboardType.rtf),
            ("text/uri-list", PasteboardType.fileURL),
            ("x-special/gnome-copied-files", PasteboardType.fileURL),
        ]
    )
    func mapsTargets(target: String, identifier: String) {
        #expect(LinuxRepresentationMap.pasteboardType(forTarget: target) == identifier)
    }

    /// ICCCM predates MIME on the clipboard. An `xclip` or an Xt-era
    /// application offers only these, and a backend that did not know them
    /// would report every such copy as empty.
    @Test(
        "the X11 text atoms map too",
        arguments: [("UTF8_STRING", PasteboardType.string), ("STRING", PasteboardType.string)]
    )
    func mapsX11Atoms(atom: String, identifier: String) {
        #expect(LinuxRepresentationMap.pasteboardType(forTarget: atom) == identifier)
    }

    @Test("a target with no identifier maps to nothing rather than to a guess")
    func refusesUnknownTargets() {
        for target in ["application/x-color", "TEXT", "application/x-qt-image", ""] {
            #expect(LinuxRepresentationMap.pasteboardType(forTarget: target) == nil)
        }
    }

    /// The whole point of composing ``RepresentationKeyMap`` instead of copying
    /// design §8's table: a row added there is a target Linux starts reading
    /// with no edit in the platform target.
    @Test("the interesting targets are derived from the wire vocabulary, not listed")
    func targetsAreDerived() {
        let targets = Set(LinuxRepresentationMap.interestingTargets)
        for entry in RepresentationKeyMap.entries {
            for target in entry.linuxTargets {
                #expect(targets.contains(target), "\(target) is in §8's table but not read")
            }
        }
    }

    @Test("the richest target comes first, so a duplicate identifier resolves the better way")
    func rankedRichestFirst() {
        let targets = LinuxRepresentationMap.interestingTargets
        guard let qualified = targets.firstIndex(of: "text/plain;charset=utf-8"),
            let bare = targets.firstIndex(of: "text/plain")
        else {
            Issue.record("both spellings of plain text should be read")
            return
        }
        #expect(qualified < bare)
    }

    @Test("writing text advertises the X11 atoms beside the MIME spellings")
    func advertisesAtoms() {
        let targets = LinuxRepresentationMap.targets(forPasteboardType: PasteboardType.string)
        #expect(targets.contains("text/plain;charset=utf-8"))
        #expect(targets.contains("text/plain"))
        #expect(targets.contains("UTF8_STRING"))
        #expect(targets.contains("STRING"))
    }

    @Test("writing an image advertises only its own MIME type")
    func imageTargets() {
        #expect(LinuxRepresentationMap.targets(forPasteboardType: PasteboardType.png) == ["image/png"])
    }

    @Test("an identifier with no Linux equivalent advertises nothing")
    func unmappableIdentifier() {
        // RTFD is an Apple bundle. Design §8 gives it no row at all: it has to
        // be flattened to HTML plus PNG before it can cross, which is a
        // transformation and not a mapping.
        #expect(LinuxRepresentationMap.targets(forPasteboardType: PasteboardType.rtfd).isEmpty)
    }

    @Test("STRING is transcoded from Latin-1 rather than stored as mojibake")
    func transcodesLatin1() {
        // 0xE9 is é in Latin-1 and is not valid UTF-8 on its own, so a byte
        // copy would fail every `String(data:encoding:.utf8)` downstream.
        let decoded = LinuxRepresentationMap.decoded(Data([0x63, 0x61, 0x66, 0xE9]), forTarget: "STRING")
        #expect(decoded.map { String(bytes: $0, encoding: .utf8) } == "café")
    }

    @Test("UTF8_STRING is passed through untouched")
    func passesUTF8Through() {
        let bytes = Data("café".utf8)
        #expect(LinuxRepresentationMap.decoded(bytes, forTarget: "UTF8_STRING") == bytes)
    }

    @Test("a URI list is reduced to its first entry, the way macOS carries one")
    func reducesURIList() {
        let body = Data("file:///tmp/a.txt\r\nfile:///tmp/b.txt".utf8)
        let decoded = LinuxRepresentationMap.decoded(body, forTarget: "text/uri-list")
        #expect(decoded.map { String(bytes: $0, encoding: .utf8) } == "file:///tmp/a.txt")
    }

    @Test("GNOME's verb line is dropped rather than stored as a file name")
    func dropsGNOMEVerb() {
        let body = Data("copy\nfile:///tmp/a.txt".utf8)
        let decoded = LinuxRepresentationMap.decoded(body, forTarget: "x-special/gnome-copied-files")
        #expect(decoded.map { String(bytes: $0, encoding: .utf8) } == "file:///tmp/a.txt")
    }

    // MARK: - Encoding

    /// The other half of the `STRING` story. `decoded` transcodes Latin-1 in;
    /// nothing transcoded back, so every caller building a payload from
    /// ``LinuxRepresentationMap/targets(forPasteboardType:)`` served UTF-8
    /// bytes under an atom that promises Latin-1.
    @Test("ASCII round-trips through STRING")
    func asciiRoundTripsThroughSTRING() throws {
        let bytes = try #require(LinuxRepresentationMap.encoded("hello", forTarget: "STRING"))
        #expect(bytes == Data("hello".utf8))
        let decoded = LinuxRepresentationMap.decoded(bytes, forTarget: "STRING")
        #expect(decoded.map { String(bytes: $0, encoding: .utf8) } == "hello")
    }

    @Test("a Latin-1 character is written as one Latin-1 byte, not two UTF-8 ones")
    func encodesLatin1() throws {
        let bytes = try #require(LinuxRepresentationMap.encoded("café", forTarget: "STRING"))
        #expect(bytes == Data([0x63, 0x61, 0x66, 0xE9]))
        let decoded = LinuxRepresentationMap.decoded(bytes, forTarget: "STRING")
        #expect(decoded.map { String(bytes: $0, encoding: .utf8) } == "café")
    }

    /// Nil is the point rather than a gap: the caller drops `STRING` from the
    /// payload, because bytes that decode to something else are worse than a
    /// target an X11 client has to ask for another way.
    @Test(
        "text Latin-1 cannot spell yields no STRING bytes, and UTF-8 bytes everywhere else",
        arguments: ["🎈", "日本語"]
    )
    func refusesUnrepresentableSTRING(text: String) {
        #expect(LinuxRepresentationMap.encoded(text, forTarget: "STRING") == nil)
        for target in ["text/plain", "text/plain;charset=utf-8", "UTF8_STRING"] {
            #expect(LinuxRepresentationMap.encoded(text, forTarget: target) == Data(text.utf8))
        }
    }

    /// What a caller relies on when `STRING` drops out: the clip is still
    /// offered, in the spellings every modern toolkit asks for first.
    @Test("dropping STRING still leaves the UTF-8 targets to advertise")
    func utf8TargetsSurviveDroppingSTRING() {
        let text = "🎈"
        let served = LinuxRepresentationMap.targets(forPasteboardType: PasteboardType.string)
            .filter { LinuxRepresentationMap.encoded(text, forTarget: $0) != nil }
        #expect(!served.contains("STRING"))
        #expect(served.contains("UTF8_STRING"))
        #expect(served.contains("text/plain;charset=utf-8"))
        #expect(served.contains("text/plain"))
    }

    // MARK: - Declared types

    @Test("declared types carry both vocabularies")
    func declaresBoth() {
        let declared = LinuxRepresentationMap.declaredTypes(
            forOfferedTargets: ["text/html", "image/png"],
            concealedHintResolvedSecret: false
        )
        #expect(declared.contains("text/html"))
        #expect(declared.contains(PasteboardType.html))
        #expect(declared.contains("image/png"))
        #expect(declared.contains(PasteboardType.png))
    }

    /// The one value-sensitive convention in `PrivacyMarkers`. Klipper stores
    /// an entry hinted anything other than `secret` normally, so the bare name
    /// must not survive into the declared types unless it resolved to a
    /// rejection — otherwise every clip a KDE application labelled `public`
    /// would be dropped.
    @Test("the KDE hint is declared only when it resolved to secret")
    func hintIsValueSensitive() {
        let offered = ["text/plain", PrivacyMarkers.kdePasswordManagerHint]

        let stored = LinuxRepresentationMap.declaredTypes(
            forOfferedTargets: offered,
            concealedHintResolvedSecret: false
        )
        #expect(!stored.contains(PrivacyMarkers.kdePasswordManagerHint))

        let rejected = LinuxRepresentationMap.declaredTypes(
            forOfferedTargets: offered,
            concealedHintResolvedSecret: true
        )
        #expect(rejected.contains(PrivacyMarkers.kdePasswordManagerHint))
    }

    @Test("declared types are deduplicated when two targets share an identifier")
    func deduplicates() {
        let declared = LinuxRepresentationMap.declaredTypes(
            forOfferedTargets: ["text/plain;charset=utf-8", "text/plain", "UTF8_STRING"],
            concealedHintResolvedSecret: false
        )
        #expect(declared.filter { $0 == PasteboardType.string }.count == 1)
    }
}

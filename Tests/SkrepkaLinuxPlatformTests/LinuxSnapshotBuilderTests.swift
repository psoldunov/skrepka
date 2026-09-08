import Foundation
import SkrepkaCore
import Testing

@testable import SkrepkaLinuxPlatform

@Suite("Linux snapshot building")
struct LinuxSnapshotBuilderTests {
    @Test("bytes are filed under the identifier the capture rules read")
    func mapsPayloads() {
        let snapshot = LinuxSnapshotBuilder.snapshot(
            offeredTargets: ["text/plain;charset=utf-8", "text/html"],
            payloads: [
                "text/plain;charset=utf-8": Data("hello".utf8),
                "text/html": Data("<b>hello</b>".utf8),
            ],
            concealedHintSecret: false
        )
        #expect(snapshot.representations[PasteboardType.string] == Data("hello".utf8))
        #expect(snapshot.representations[PasteboardType.html] == Data("<b>hello</b>".utf8))
    }

    /// Both spellings of plain text map to one identifier, so the ranking is
    /// what decides which body is stored — and the charset-qualified one is the
    /// one that says what encoding it is in.
    @Test("the richer of two targets sharing an identifier wins")
    func richestWins() {
        let snapshot = LinuxSnapshotBuilder.snapshot(
            offeredTargets: ["text/plain", "text/plain;charset=utf-8"],
            payloads: [
                "text/plain": Data("bare".utf8),
                "text/plain;charset=utf-8": Data("qualified".utf8),
            ],
            concealedHintSecret: false
        )
        #expect(snapshot.representations[PasteboardType.string] == Data("qualified".utf8))
    }

    @Test("a captured clipboard decides as a capture")
    func capturesThroughTheRules() {
        let snapshot = LinuxSnapshotBuilder.snapshot(
            offeredTargets: ["text/plain;charset=utf-8"],
            payloads: ["text/plain;charset=utf-8": Data("hello".utf8)],
            concealedHintSecret: false
        )
        guard case .captured(let item) = CaptureRules().decide(snapshot) else {
            Issue.record("a plain-text clipboard should capture")
            return
        }
        #expect(item.kind == .text)
        #expect(item.text == "hello")
    }

    /// The end-to-end privacy assertion. KDE's hint means reject outright —
    /// verified against `klipper/historymodel.cpp`, which returns before
    /// inserting — so it has to reach `CaptureRules` as a rejection and not as
    /// a concealed row that gets stored and masked.
    @Test("a secret-hinted clipboard is rejected, not stored")
    func rejectsSecrets() {
        let snapshot = LinuxSnapshotBuilder.snapshot(
            offeredTargets: ["text/plain;charset=utf-8", PrivacyMarkers.kdePasswordManagerHint],
            payloads: ["text/plain;charset=utf-8": Data("hunter2".utf8)],
            concealedHintSecret: true
        )
        #expect(snapshot.representations.isEmpty)
        #expect(CaptureRules().decide(snapshot) == .rejectedPrivacyMarker)
    }

    @Test("a hint that did not say secret leaves the clip alone")
    func storesNonSecrets() {
        let snapshot = LinuxSnapshotBuilder.snapshot(
            offeredTargets: ["text/plain;charset=utf-8", PrivacyMarkers.kdePasswordManagerHint],
            payloads: ["text/plain;charset=utf-8": Data("public note".utf8)],
            concealedHintSecret: false
        )
        #expect(CaptureRules().decide(snapshot).item?.text == "public note")
    }

    /// Telling an empty clipboard from an unreadable one is what
    /// `CaptureRules.emptyReason(declaredTypes:)` exists for, and it needs the
    /// identifiers in `declaredTypes` to do it.
    @Test("a clipboard that offered something readable and yielded nothing reads as unreadable")
    func unreadableRatherThanEmpty() {
        let snapshot = LinuxSnapshotBuilder.snapshot(
            offeredTargets: ["text/plain;charset=utf-8"],
            payloads: [:],
            concealedHintSecret: false
        )
        #expect(CaptureRules().decide(snapshot) == .rejectedUnreadable)
    }

    @Test("a clipboard offering nothing Skrepka reads is empty rather than unreadable")
    func emptyRatherThanUnreadable() {
        let snapshot = LinuxSnapshotBuilder.snapshot(
            offeredTargets: ["application/x-qt-image", "TEXT"],
            payloads: [:],
            concealedHintSecret: false
        )
        #expect(CaptureRules().decide(snapshot) == .rejectedEmpty)
    }

    @Test("a copied file list becomes a file entry naming every file")
    func fileSelection() {
        let body = Data("copy\nfile:///tmp/a.txt\nfile:///tmp/b.txt".utf8)
        let snapshot = LinuxSnapshotBuilder.snapshot(
            offeredTargets: ["x-special/gnome-copied-files"],
            payloads: ["x-special/gnome-copied-files": body],
            concealedHintSecret: false
        )
        #expect(snapshot.fileURLs.map(\.lastPathComponent) == ["a.txt", "b.txt"])
        // The payload carries only the first, exactly as `PasteboardReader`
        // leaves it on macOS: one URL in the representation, all of them beside.
        #expect(
            snapshot.representations[PasteboardType.fileURL]
                .map { String(bytes: $0, encoding: .utf8) } == "file:///tmp/a.txt"
        )
        guard case .captured(let item) = CaptureRules().decide(snapshot) else {
            Issue.record("a file list should capture")
            return
        }
        #expect(item.kind == .file)
        #expect(item.text == "a.txt\nb.txt")
    }

    @Test("the standard target is preferred over GNOME's when both are offered")
    func prefersStandardURIList() {
        let snapshot = LinuxSnapshotBuilder.snapshot(
            offeredTargets: ["text/uri-list", "x-special/gnome-copied-files"],
            payloads: [
                "text/uri-list": Data("file:///tmp/standard.txt".utf8),
                "x-special/gnome-copied-files": Data("copy\nfile:///tmp/gnome.txt".utf8),
            ],
            concealedHintSecret: false
        )
        #expect(snapshot.fileURLs.map(\.lastPathComponent) == ["standard.txt"])
    }

    @Test("a JPEG-only copy is an image rather than nothing")
    func jpegIsAnImage() {
        let snapshot = LinuxSnapshotBuilder.snapshot(
            offeredTargets: ["image/jpeg"],
            payloads: ["image/jpeg": Data([0xFF, 0xD8, 0xFF, 0xE0])],
            concealedHintSecret: false
        )
        #expect(CaptureRules().decide(snapshot).item?.kind == .image)
    }

    @Test("an empty representation is dropped rather than stored")
    func dropsEmptyBodies() {
        let snapshot = LinuxSnapshotBuilder.snapshot(
            offeredTargets: ["text/html", "text/plain;charset=utf-8"],
            payloads: ["text/html": Data(), "text/plain;charset=utf-8": Data("hello".utf8)],
            concealedHintSecret: false
        )
        #expect(snapshot.representations[PasteboardType.html] == nil)
        #expect(snapshot.representations[PasteboardType.string] != nil)
    }

    @Test("no source bundle identifier is invented")
    func noSourceBundleID() {
        let snapshot = LinuxSnapshotBuilder.snapshot(
            offeredTargets: ["text/plain"],
            payloads: ["text/plain": Data("x".utf8)],
            concealedHintSecret: false
        )
        #expect(snapshot.sourceBundleID == nil)
    }
}

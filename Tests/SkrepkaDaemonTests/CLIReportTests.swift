import Foundation
import SkrepkaIPC
import Testing

@testable import SkrepkaCLI
@testable import SkrepkaLinuxPlatform

/// Golden output shapes.
///
/// `--json` is what the Phase 8 packaging tests script against, so the bytes
/// are the contract and a literal is the only assertion that catches a key
/// quietly renamed. The text renderings are checked against a fixed time zone
/// rather than the machine's, so the goldens do not depend on where the test
/// runs.
@Suite("CLI reports")
struct CLIReportTests {
    private static let stampText = "2026-01-02T03:04:05Z"

    private func stamp() throws -> Date {
        try #require(ISO8601DateFormatter().date(from: Self.stampText))
    }

    private func history(_ createdAt: Date) -> HistoryDocument {
        HistoryDocument(
            clips: [
                ClipDocument(
                    contentHash: "a1b2c3d4e5f6",
                    preview: "hello world",
                    kind: "text",
                    isPinned: true,
                    createdAt: createdAt,
                    byteCount: 11,
                    representations: ["text/plain;charset=utf-8"]
                ),
                ClipDocument(
                    contentHash: "ffffffffffff",
                    preview: "a picture",
                    kind: "image",
                    isPinned: false,
                    createdAt: createdAt,
                    byteCount: 2048,
                    representations: ["image/png"]
                ),
            ],
            total: 42
        )
    }

    @Test("`list --json` is the daemon's document, verbatim")
    func historyJSON() throws {
        let json = try SkrepkaDocumentCoding.encode(history(try stamp()))
        let expected = """
            {"clips":[{"byteCount":11,"contentHash":"a1b2c3d4e5f6","createdAt":"\(Self.stampText)",\
            "hasPreview":false,"isConcealed":false,"isPinned":true,"kind":"text",\
            "preview":"hello world","representations":["text/plain;charset=utf-8"]},\
            {"byteCount":2048,"contentHash":"ffffffffffff","createdAt":"\(Self.stampText)",\
            "hasPreview":false,"isConcealed":false,"isPinned":false,"kind":"image",\
            "preview":"a picture","representations":["image/png"]}],"total":42,"version":\(SkrepkaInterface.version)}
            """
        #expect(json == expected)
    }

    @Test("`list` numbers its lines, and the numbers are what `copy` takes")
    func historyText() throws {
        let text = HistoryReport.text(history(try stamp()), timeZone: .gmt)
        #expect(
            text == """
                  1 * a1b2c3d4  text    01-02 03:04  hello world (11 B)
                  2   ffffffff  image   01-02 03:04  a picture (2.0 KB)

                Showing 2 of 42.
                """
        )
    }

    @Test("`list` marks a file entry whose contents did not sync")
    func unsyncedFilesAreMarked() throws {
        let clip = ClipDocument(
            contentHash: "0123456789ab",
            preview: "shot.png",
            kind: "file",
            isPinned: false,
            createdAt: try stamp(),
            byteCount: nil,
            representations: ["text/uri-list"],
            filesStatus: ClipDocument.FilesStatusName.notSynced
        )
        let text = HistoryReport.text(HistoryDocument(clips: [clip], total: 1), timeZone: .gmt)
        #expect(text == "  1   01234567  file    01-02 03:04  shot.png [contents not synced]")
    }

    @Test("an empty history says so rather than printing nothing")
    func emptyHistoryText() {
        #expect(HistoryReport.text(HistoryDocument(clips: [], total: 0)) == "No clipboard history yet.")
    }

    @Test("`doctor --json` is the daemon's document, verbatim")
    func diagnosticsJSON() throws {
        let json = try SkrepkaDocumentCoding.encode(diagnostics(try stamp()))
        let expected = """
            {"daemonVersion":"0.1.4","deviceFingerprint":"ab-cd-ef",\
            "network":{"isPublished":true,"pairedCount":2,"responder":"avahi","sightedCount":1,\
            "syncPort":5555},\
            "problems":["Nothing on this session can watch the clipboard."],\
            "session":{"backend":"wlrDataControl","backendName":"wlr-data-control",\
            "desktop":"sway","isBlocking":true,"isXWaylandFallback":false,"restarts":1,\
            "waylandDisplay":"wayland-0","waylandGlobals":["wl_seat","zwlr_data_control_manager_v1"]},\
            "storage":{"itemCount":7,"lastCapturedAt":"\(Self.stampText)","mode":"0600",\
            "path":"/home/deck/.local/share/skrepka/history.sqlite"},\
            "version":\(SkrepkaInterface.version)}
            """
        #expect(json == expected)
    }

    @Test("`doctor` leads with the problems")
    func diagnosticsText() throws {
        let text = DoctorReport.text(diagnostics(try stamp()), timeZone: .gmt)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "PROBLEMS")
        #expect(lines.dropFirst().first == "  - Nothing on this session can watch the clipboard.")
        #expect(text.contains("  backend      wlr-data-control (wlrDataControl)"))
        #expect(text.contains("  restarts     1"))
        #expect(text.contains("  peers        2 paired, 1 in sight"))
        #expect(text.contains("  last capture 01-02 03:04"))
    }

    @Test("`doctor` and its JSON show the avahi publication remedy")
    func avahiPublicationRemedyIsVisible() throws {
        let refusal = AvahiError.refused(
            method: AvahiNames.Server.entryGroupNew,
            name: "org.freedesktop.Avahi.NotPermittedError",
            detail: "Not permitted"
        )
        let problem = "Peer discovery or publishing is not working: \(refusal)"
        let report = diagnostics(try stamp(), problems: [problem])
        let text = DoctorReport.text(report, timeZone: .gmt)
        let json = try SkrepkaDocumentCoding.encode(report)

        #expect(text.contains("disable-user-service-publishing=yes"))
        #expect(text.contains("sudo systemctl restart avahi-daemon"))
        #expect(json.contains("disable-user-service-publishing=yes"))
        #expect(json.contains("sudo systemctl restart avahi-daemon"))
    }

    @Test("a clean machine says so")
    func healthyDiagnosticsText() throws {
        let clean = diagnostics(try stamp(), problems: [])
        #expect(
            DoctorReport.text(clean, timeZone: .gmt).hasPrefix("Everything Skrepka checks is working."))
    }

    @Test("an extension submission accounts for native Wayland capture")
    func nativeWaylandCoverage() throws {
        let coveredDocument = diagnostics(
            try stamp(),
            problems: [],
            isXWaylandFallback: true,
            nativeWaylandCapture: .shellExtension
        )
        let uncoveredDocument = diagnostics(
            try stamp(),
            problems: [],
            isXWaylandFallback: true
        )
        let covered = DoctorReport.text(coveredDocument, timeZone: .gmt)
        let uncovered = DoctorReport.text(uncoveredDocument, timeZone: .gmt)

        #expect(covered.contains("GNOME Shell extension covers native Wayland copies"))
        #expect(!covered.contains("copies from Wayland apps are invisible"))
        #expect(uncovered.contains("copies from Wayland apps are invisible"))
    }

    private func diagnostics(
        _ stamp: Date,
        problems: [String] = ["Nothing on this session can watch the clipboard."],
        isXWaylandFallback: Bool = false,
        nativeWaylandCapture: DiagnosticsDocument.Session.NativeWaylandCapture? = nil
    ) -> DiagnosticsDocument {
        DiagnosticsDocument(
            daemonVersion: "0.1.4",
            deviceFingerprint: "ab-cd-ef",
            session: DiagnosticsDocument.Session(
                backend: isXWaylandFallback ? "xFixes" : "wlrDataControl",
                backendName: isXWaylandFallback ? "X11 (XFIXES)" : "wlr-data-control",
                waylandGlobals: ["wl_seat", "zwlr_data_control_manager_v1"],
                waylandDisplay: "wayland-0",
                x11Display: isXWaylandFallback ? ":0" : nil,
                desktop: isXWaylandFallback ? "GNOME" : "sway",
                isXWaylandFallback: isXWaylandFallback,
                problem: nil,
                isBlocking: true,
                restarts: 1,
                nativeWaylandCapture: nativeWaylandCapture
            ),
            network: DiagnosticsDocument.Network(
                responder: "avahi",
                responderProblem: nil,
                isPublished: true,
                syncPort: 5555,
                pairedCount: 2,
                sightedCount: 1
            ),
            storage: DiagnosticsDocument.Storage(
                path: "/home/deck/.local/share/skrepka/history.sqlite",
                itemCount: 7,
                lastCapturedAt: stamp,
                mode: "0600"
            ),
            problems: problems
        )
    }
}

// MARK: - Column widths

extension CLIReportTests {
    @Test("`list` widens its kind column to the longest kind it prints, so every row still lines up")
    func kindColumnFitsTheLongestKind() throws {
        let picture = ClipDocument(
            contentHash: "0123456789ab",
            preview: "shot.png",
            kind: "imageFile",
            isPinned: false,
            createdAt: try stamp(),
            byteCount: nil,
            representations: ["text/uri-list"]
        )
        let text = HistoryReport.text(
            HistoryDocument(clips: [try #require(history(try stamp()).clips.first), picture], total: 2),
            timeZone: .gmt)
        #expect(
            text == """
                  1 * a1b2c3d4  text       01-02 03:04  hello world (11 B)
                  2   01234567  imageFile  01-02 03:04  shot.png
                """
        )
    }
}

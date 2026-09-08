import SkrepkaCore
import Testing

@testable import SkrepkaLinuxPlatform

/// The decision table, over synthetic global lists.
///
/// Every branch here is a compositor this project has no hardware for — the one
/// it does have runs KDE, and the CI container runs Sway. That is exactly why
/// the deciding half of ``SessionProbe`` takes a list of strings rather than a
/// live connection.
@Suite("Session probe")
struct SessionProbeTests {
    private func decide(
        globals: [String],
        wayland: String? = "wayland-0",
        x11: String? = nil,
        desktop: String? = nil
    ) -> SessionProbe.Report {
        SessionProbe.decide(
            waylandGlobals: globals,
            waylandDisplay: wayland,
            x11Display: x11,
            desktop: desktop
        )
    }

    @Test("ext-data-control is chosen when advertised")
    func choosesExt() {
        let report = decide(globals: ["wl_seat", SessionProbe.extGlobal])
        #expect(report.backend == .extDataControl)
        #expect(report.problem == nil)
    }

    @Test("wlr-data-control is chosen when it is the only one, and reported as deprecated")
    func choosesWlr() {
        let report = decide(globals: ["wl_seat", SessionProbe.wlrGlobal])
        #expect(report.backend == .wlrDataControl)
        #expect(report.problem == .deprecatedProtocolOnly)
        // Deprecated is not broken: nothing here should reach the user.
        #expect(report.problem?.isBlocking == false)
        #expect(report.problem?.asDiagnosticsProblem == nil)
    }

    /// The Plasma 6.4 case, and the reason the order in the table is not
    /// arbitrary. KWin's port to `ext-data-control-v1` landed in Plasma 6.4 and
    /// that release advertises **both** globals from one implementation, so a
    /// chooser that took the first global it recognised would bind two devices
    /// to one seat and record every copy twice. Plasma 6.5 dropped the legacy
    /// one; the project's own Steam Deck rig runs 6.4.3.
    @Test("ext wins when a compositor advertises both, as Plasma 6.4 does")
    func prefersExtOverWlr() {
        let report = decide(globals: [SessionProbe.wlrGlobal, "wl_seat", SessionProbe.extGlobal])
        #expect(report.backend == .extDataControl)
        #expect(report.problem == nil)
    }

    @Test("X11 is the fallback when a Wayland session offers no data control")
    func fallsBackToX11() {
        let report = decide(globals: ["wl_seat", "wl_compositor"], x11: ":0")
        #expect(report.backend == .xFixes)
        #expect(report.problem == nil)
        // Lossy, and named as such: XWayland sees only what XWayland clients
        // put on the clipboard.
        #expect(report.isXWaylandFallback)
    }

    @Test("a pure X11 session is not an XWayland fallback")
    func pureX11() {
        let report = decide(globals: [], wayland: nil, x11: ":0")
        #expect(report.backend == .xFixes)
        #expect(!report.isXWaylandFallback)
    }

    @Test("no data control and no X11 is a reported failure, not a silent one")
    func unwatchableSession() {
        let report = decide(globals: ["wl_seat", "wl_compositor"], desktop: "weston")
        #expect(report.backend == nil)
        #expect(report.problem == .noDataControlProtocol)
        #expect(report.problem?.isBlocking == true)
        #expect(report.problem?.asDiagnosticsProblem?.problem == .clipboardSessionUnsupported)
    }

    /// GNOME is a supported configuration with a known remedy, not an error —
    /// Mutter implements no data-control protocol at all, so this is the
    /// expected finding there and the message has to name the Shell extension.
    ///
    /// Asserted here and unverified against a live session: there is no GNOME
    /// machine on this project (OQ-3). It is the first thing to run when one
    /// appears, because it is the message every GNOME user meets first.
    @Test("GNOME gets the extension remedy rather than the generic one")
    func gnomeIsNamed() {
        let report = decide(globals: ["wl_seat"], desktop: "ubuntu:GNOME")
        #expect(report.problem == .gnomeWithoutShellExtension)
        #expect(report.problem?.asDiagnosticsProblem?.problem == .clipboardNeedsShellExtension)
        #expect(
            report.problem?.asDiagnosticsProblem?.problem.remedy
                .contains("GNOME Shell extension") == true
        )
    }

    @Test(
        "XDG_CURRENT_DESKTOP is a colon-separated list matched case insensitively",
        arguments: [
            ("GNOME", true),
            ("ubuntu:GNOME", true),
            ("gnome", true),
            ("GNOME-Classic:GNOME", true),
            ("KDE", false),
            ("sway", false),
            ("", false),
        ]
    )
    func desktopMatching(desktop: String, isGNOME: Bool) {
        #expect(SessionProbe.isGNOME(desktop) == isGNOME)
    }

    @Test("no desktop set is not GNOME")
    func noDesktop() {
        #expect(!SessionProbe.isGNOME(nil))
    }

    /// A GNOME session that has XWayland running is captured through X11 rather
    /// than reported as broken — lossy, and better than nothing.
    @Test("GNOME with XWayland captures instead of reporting")
    func gnomeWithXWayland() {
        let report = decide(globals: ["wl_seat"], x11: ":0", desktop: "GNOME")
        #expect(report.backend == .xFixes)
        #expect(report.problem == nil)
        #expect(report.isXWaylandFallback)
    }

    @Test("the globals are recorded whatever the decision")
    func recordsEvidence() {
        let globals = ["wl_seat", "wl_compositor", "wl_shm"]
        #expect(decide(globals: globals).waylandGlobals == globals)
    }
}

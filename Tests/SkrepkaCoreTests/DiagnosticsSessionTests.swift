import Foundation
import Testing

@testable import SkrepkaCore

/// The Linux clipboard session's hand-off into the diagnostics the user sees.
///
/// Its own suite rather than a few more cases in `DiagnosticsReportTests`,
/// because every one of these turns on the one field that is nil on macOS, and
/// the two rules worth pinning down — that a session problem outranks a
/// permission and loses to a broken store — are about ranking rather than about
/// the report.
@Suite("Diagnostics clipboard session")
struct DiagnosticsSessionTests {
    private func snapshot(
        session: DiagnosticsProblem.SessionProblem? = nil,
        access: PasteboardAccess = .alwaysAllow,
        blocked: Bool = false,
        accessibility: Bool = true,
        storage: DiagnosticsSnapshot.Storage = .onDisk(path: "/tmp/skrepka.store")
    ) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            appVersion: "0.1.0 (1)",
            systemVersion: "Version 26.6.2",
            pasteboardAccess: access,
            isCaptureBlocked: blocked,
            lastCapturedAt: nil,
            probeSucceeded: false,
            isAccessibilityTrusted: accessibility,
            pasteAutomatically: true,
            loginItem: .enabled,
            storage: storage,
            itemCount: 7,
            clipboardSession: session
        )
    }

    @Test("Each session state surfaces as its own problem")
    func sessionStatesSurface() {
        // Guards the hand-off itself: `ranked` grew the parameter before
        // anything passed one, so both cases were unreachable from a snapshot
        // however the session was configured.
        #expect(snapshot(session: .noDataControlProtocol).primaryProblem == .clipboardSessionUnsupported)
        #expect(
            snapshot(session: .gnomeWithoutShellExtension).primaryProblem
                == .clipboardNeedsShellExtension
        )
    }

    @Test("A session with no protocol outranks a clipboard denial")
    func sessionOutranksTheDenial() {
        // Deliberate, per the doc comment on `ranked(session:)`: a session
        // nothing can watch also looks like a run of unreadable reads, and
        // sending the user to a permission their system does not have is worse
        // than saying nothing.
        let denied = snapshot(session: .noDataControlProtocol, access: .alwaysDeny, blocked: true)
        #expect(denied.clipboardStatus == .blocked)
        #expect(denied.primaryProblem == .clipboardSessionUnsupported)
    }

    @Test("A session problem outranks missing paste-back too")
    func sessionOutranksAccessibility() {
        let noPasteBack = snapshot(session: .gnomeWithoutShellExtension, accessibility: false)
        #expect(noPasteBack.primaryProblem == .clipboardNeedsShellExtension)
    }

    @Test("A store that cannot be opened still outranks the session")
    func storageOutranksTheSession() {
        // Losing every future clip beats not recording new ones.
        let broken = snapshot(session: .noDataControlProtocol, storage: .inMemory(reason: "disk full"))
        #expect(broken.primaryProblem == .storageUnavailable)
    }

    @Test("No session state leaves the ranking exactly as it was")
    func noSessionChangesNothing() {
        #expect(snapshot().primaryProblem == nil)
        #expect(snapshot(access: .alwaysDeny).primaryProblem == .clipboardAccessDenied)
    }

    @Test("The report names which session state fired")
    func reportNamesTheSessionState() {
        let unsupported = DiagnosticsReport.text(for: snapshot(session: .noDataControlProtocol))
        #expect(
            unsupported.contains(
                "Clipboard session: \(DiagnosticsProblem.clipboardSessionUnsupported.headline)"
            )
        )
        // The two states must not render the same line, or the report says a
        // session is broken without saying which of the two it is.
        let gnome = DiagnosticsReport.text(for: snapshot(session: .gnomeWithoutShellExtension))
        #expect(
            gnome.contains(
                "Clipboard session: \(DiagnosticsProblem.clipboardNeedsShellExtension.headline)"
            )
        )
        #expect(!gnome.contains(DiagnosticsProblem.clipboardSessionUnsupported.headline))
    }

    @Test("The report still carries the session line when the store is the headline problem")
    func reportKeepsTheSessionLineUnderAStorageFailure() {
        // The `Problem:` line reports the store, so the session line is the
        // only place the compositor finding survives — and a bug report from a
        // machine with both faults needs both.
        let text = DiagnosticsReport.text(
            for: snapshot(session: .noDataControlProtocol, storage: .inMemory(reason: "disk full"))
        )
        #expect(text.contains("Clipboard session: "))
        #expect(text.contains(DiagnosticsProblem.storageUnavailable.summary))
    }

    @Test("A macOS report has no session row at all")
    func reportOmitsTheRowOnMacOS() {
        #expect(!DiagnosticsReport.text(for: snapshot()).contains("Clipboard session"))
    }
}

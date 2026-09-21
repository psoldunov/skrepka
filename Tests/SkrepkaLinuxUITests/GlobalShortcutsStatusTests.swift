import Testing

@testable import SkrepkaLinuxUI

/// What `skrepka-gui --status` and the journal say about the shortcut.
///
/// Pinned because these lines are the only report a user gets of a shortcut
/// that silently never bound — the 0.2.1 failure on the Steam Deck — and a
/// line that blurs "the portal refused" into "the user cancelled" sends them
/// to the wrong fix.
@Suite("Global shortcut: status wording")
struct GlobalShortcutsStatusTests {
    @Test("a portal response code says who ended the request")
    func responseCodes() {
        #expect(PortalResponse.describe(code: 0) == "done")
        #expect(PortalResponse.describe(code: 1).contains("cancelled"))
        #expect(PortalResponse.describe(code: 2).contains("response 2"))
    }

    @Test("a registration the portal accepted names the app ID")
    func acceptedRegistration() {
        let line = GlobalShortcuts.describeRegistration(
            .success(.tuple([])), applicationID: "dev.soldunov.Skrepka.App")
        #expect(line == "registered as dev.soldunov.Skrepka.App")
    }

    @Test("a refused registration carries the portal's reason and is not fatal")
    func refusedRegistration() {
        let error = DBusError(
            name: "org.freedesktop.portal.Error.Failed",
            message: "Connection already associated with an application ID")
        let line = GlobalShortcuts.describeRegistration(.failure(error), applicationID: "x")
        #expect(line.contains("Connection already associated"))
        #expect(line.contains("names the app from its launcher"))
    }

    @Test("a portal without the host registry is told apart from a refusal")
    func portalWithoutRegistry() {
        let error = DBusError(name: "org.freedesktop.DBus.Error.UnknownMethod", message: "no such method")
        let line = GlobalShortcuts.describeRegistration(.failure(error), applicationID: "x")
        #expect(line.contains("predates app registration"))
    }

    @Test(
        "every state reads as one line",
        arguments: [
            (GlobalShortcutsState.bound("Meta+Shift+V"), "bound to Meta+Shift+V"),
            (.unbound("cancelled in the desktop's prompt"), "not bound — cancelled in the desktop's prompt"),
            (
                .unavailable("the desktop portal is not running"),
                "unavailable — the desktop portal is not running"
            ),
            (.connecting, "connecting to the Global Shortcuts portal"),
        ]
    )
    func summaries(state: GlobalShortcutsState, expected: String) {
        #expect(state.summary == expected)
    }
}

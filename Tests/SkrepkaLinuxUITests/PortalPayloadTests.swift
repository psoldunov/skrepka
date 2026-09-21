import Testing

@testable import SkrepkaLinuxUI

@Suite("Global Shortcuts portal payloads")
struct PortalPayloadTests {
    @Test("Response extracts the result code and vardict")
    func response() {
        let value = DBusValue.tuple([
            .uint32(0),
            .dictionary(["session_handle": .string("/session/skrepka")]),
        ])
        #expect(
            PortalResponse.parse(value)
                == PortalResponse(
                    code: 0,
                    results: ["session_handle": .string("/session/skrepka")]
                ))
    }

    @Test("Activated carries the optional compositor activation token")
    func activation() {
        let value = DBusValue.tuple([
            .objectPath("/session/skrepka"),
            .string("show-picker"),
            .uint64(42),
            .dictionary(["activation_token": .string("wayland-token")]),
        ])
        #expect(
            PortalActivation.parse(value)
                == PortalActivation(
                    session: "/session/skrepka",
                    shortcutID: "show-picker",
                    activationToken: "wayland-token"
                ))
    }

    @Test("Bound shortcut uses portal's display-ready description")
    func shortcuts() {
        let value = DBusValue.array(
            elementSignature: "(sa{sv})",
            values: [
                .tuple([
                    .string("show-picker"),
                    .dictionary(["trigger_description": .string("Super+Shift+V")]),
                ])
            ]
        )
        #expect(
            PortalShortcut.parseList(value)
                == [PortalShortcut(identifier: "show-picker", triggerDescription: "Super+Shift+V")]
        )
    }

    @Test("Preferred trigger follows the XDG Shortcuts grammar")
    func trigger() {
        #expect(GlobalShortcutTrigger.showPicker == "LOGO+SHIFT+v")
    }

    @Test("Request path is predictable before the portal method call")
    func requestPath() {
        #expect(
            PortalRequestPath.make(uniqueName: ":1.42", token: "skrepka_123")
                == "/org/freedesktop/portal/desktop/request/1_42/skrepka_123")
    }
}

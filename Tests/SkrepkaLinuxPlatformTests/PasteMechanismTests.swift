import Testing

@testable import SkrepkaLinuxPlatform

@Suite("Automatic paste mechanism")
struct PasteMechanismTests {
    @Test("virtual keyboard wins when the live Wayland registry advertises it")
    func virtualKeyboard() {
        #expect(
            PasteMechanism.decide(
                waylandGlobals: [PasteMechanism.virtualKeyboardGlobal],
                waylandConnected: true,
                x11Connected: true
            ) == .virtualKeyboard
        )
    }

    @Test("other live Wayland sessions use the RemoteDesktop portal")
    func portal() {
        #expect(
            PasteMechanism.decide(
                waylandGlobals: ["wl_seat", "wl_compositor"],
                waylandConnected: true,
                x11Connected: true
            ) == .remoteDesktopPortal
        )
    }

    @Test("a live X11 session uses XTest")
    func xTest() {
        #expect(
            PasteMechanism.decide(
                waylandGlobals: [],
                waylandConnected: false,
                x11Connected: true
            ) == .xTest
        )
    }

    @Test("no live input surface stays copy-only")
    func copyOnly() {
        #expect(
            PasteMechanism.decide(
                waylandGlobals: [],
                waylandConnected: false,
                x11Connected: false
            ) == .copyOnly
        )
    }

    @Test("the virtual keyboard keymap names Ctrl and V")
    func keymap() {
        #expect(VirtualKeyboardPaster.keymap.hasSuffix("\0"))
        #expect(VirtualKeyboardPaster.keymap.contains("modifier_map Control"))
        #expect(VirtualKeyboardPaster.keymap.contains("key <AB04>"))
    }
}

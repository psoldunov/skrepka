import DBUS
import Testing

@testable import SkrepkaLinuxPlatform

/// Filling a display in from the systemd user manager, for a daemon that
/// started before the desktop exported one.
///
/// The case that matters is Plasma's login: `skrepkad.service` comes up with
/// `default.target`, before KWin runs, so its own environment names no display
/// while the manager's names one a few seconds later.
@Suite("User manager environment")
struct UserManagerEnvironmentTests {
    private let manager = [
        "WAYLAND_DISPLAY": "wayland-0",
        "DISPLAY": ":0",
        "XAUTHORITY": "/run/user/1000/xauth_abc",
        "XDG_SESSION_TYPE": "wayland",
        "XDG_CURRENT_DESKTOP": "KDE",
    ]

    @Test("only the display variables are read from the manager's assignments")
    func parsesDisplayKeys() {
        let parsed = UserManagerEnvironment.parse([
            "PATH=/usr/bin", "WAYLAND_DISPLAY=wayland-0", "DISPLAY=:0", "XDG_CURRENT_DESKTOP=KDE",
            "QT_WAYLAND_RECONNECT=1",
        ])
        #expect(parsed == ["WAYLAND_DISPLAY": "wayland-0", "DISPLAY": ":0", "XDG_CURRENT_DESKTOP": "KDE"])
    }

    @Test("an assignment with no value, or no equals sign, is skipped")
    func skipsMalformed() {
        #expect(UserManagerEnvironment.parse(["WAYLAND_DISPLAY=", "DISPLAY"]).isEmpty)
    }

    @Test("a value containing an equals sign is kept whole")
    func keepsEqualsInValue() {
        let parsed = UserManagerEnvironment.parse(["XAUTHORITY=/tmp/a=b"])
        #expect(parsed["XAUTHORITY"] == "/tmp/a=b")
    }

    @Test("a daemon started without a display takes the manager's")
    func fillsMissingDisplay() {
        let process = ["HOME": "/home/u", "XDG_RUNTIME_DIR": "/run/user/1000"]
        let filled = UserManagerEnvironment.filling(process, from: manager)
        #expect(filled["WAYLAND_DISPLAY"] == "wayland-0")
        #expect(filled["XDG_CURRENT_DESKTOP"] == "KDE")
        #expect(filled["HOME"] == "/home/u")
    }

    @Test("a daemon started with a display keeps its own")
    func keepsOwnDisplay() {
        let process = ["WAYLAND_DISPLAY": "wayland-1"]
        #expect(UserManagerEnvironment.filling(process, from: manager) == process)
    }

    @Test("a manager with no display changes nothing")
    func managerWithoutDisplay() {
        let process = ["HOME": "/home/u"]
        let filled = UserManagerEnvironment.filling(process, from: ["XDG_CURRENT_DESKTOP": "KDE"])
        #expect(filled == process)
    }

    @Test("an empty display name is no display")
    func emptyIsNoDisplay() {
        #expect(!UserManagerEnvironment.hasDisplay(["WAYLAND_DISPLAY": "", "DISPLAY": ""]))
        #expect(UserManagerEnvironment.hasDisplay(["DISPLAY": ":0"]))
    }

    @Test("a Properties.Get reply's variant array of assignments is read")
    func decodesReply() {
        let body: [DBusValue] = [
            .variant(
                DBusVariant(
                    .array([.string("PATH=/usr/bin"), .string("WAYLAND_DISPLAY=wayland-0"), .uint32(7)]))
            )
        ]
        #expect(UserManagerEnvironment.displayVariables(inReply: body) == ["WAYLAND_DISPLAY": "wayland-0"])
    }

    @Test("a reply of any other shape is no answer")
    func rejectsOtherReplies() {
        #expect(UserManagerEnvironment.displayVariables(inReply: []) == nil)
        #expect(UserManagerEnvironment.displayVariables(inReply: [.array([.string("DISPLAY=:0")])]) == nil)
        #expect(
            UserManagerEnvironment.displayVariables(inReply: [.variant(DBusVariant(.string("DISPLAY=:0")))])
                == nil)
    }

    @Test("the bus comes from the environment given, never from the process's own")
    func busAddress() {
        #expect(UserManagerEnvironment.busAddress(in: [:]) == nil)
        #expect(
            UserManagerEnvironment.busAddress(in: ["DBUS_SESSION_BUS_ADDRESS": "unix:path=/x/bus"])
                == "unix:path=/x/bus")
        #expect(
            UserManagerEnvironment.busAddress(in: ["XDG_RUNTIME_DIR": "/run/user/1000"])
                == "unix:path=/run/user/1000/bus")
    }
}

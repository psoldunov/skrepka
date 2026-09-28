import Foundation
import Testing

@testable import SkrepkaLinuxPlatform

/// Finding an X11 session's cookie in the Xauthority file the systemd user
/// manager names, for a daemon whose own environment names none.
///
/// Nothing here calls ``XAuthority/adopt(from:)`` with a file that holds a
/// cookie: `XSetAuthorization` is process-wide, and would change how every
/// other X11 test in this process connects.
@Suite("Xauthority cookie")
struct XAuthorityTests {
    private static let sampleCookie: [UInt8] = Array(0..<16)

    /// One entry in `XauWriteAuth`'s layout.
    private static func entry(
        family: UInt16,
        address: String,
        number: String,
        name: String = XAuthority.cookieName,
        data: [UInt8] = sampleCookie
    ) -> [UInt8] {
        func counted(_ bytes: [UInt8]) -> [UInt8] {
            [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)] + bytes
        }
        return [UInt8(family >> 8), UInt8(family & 0xFF)]
            + counted(Array(address.utf8)) + counted(Array(number.utf8))
            + counted(Array(name.utf8)) + counted(data)
    }

    private static func cookie(in bytes: [UInt8], display: String = ":0") -> [UInt8]? {
        guard let number = XAuthority.displayNumber(of: display) else { return nil }
        return XAuthority.cookie(in: XAuthority.entries(in: bytes), number: number, hostname: "deck")
    }

    @Test("an SDDM-style wildcard entry matches whatever the host is called")
    func wildcardEntry() {
        let file = Self.entry(family: XAuthority.familyWild, address: "", number: "0")
        #expect(Self.cookie(in: file) == Self.sampleCookie)
    }

    @Test("a local entry matches only this host's name")
    func localEntry() {
        let local = Self.entry(family: XAuthority.familyLocal, address: "deck", number: "0")
        let other = Self.entry(family: XAuthority.familyLocal, address: "laptop", number: "0")
        #expect(Self.cookie(in: local) == Self.sampleCookie)
        #expect(Self.cookie(in: other) == nil)
    }

    @Test("the display number must match, unless the entry leaves it empty")
    func displayNumber() {
        let second = Self.entry(family: XAuthority.familyWild, address: "", number: "1")
        let any = Self.entry(family: XAuthority.familyWild, address: "", number: "")
        #expect(Self.cookie(in: second) == nil)
        #expect(Self.cookie(in: second, display: ":1.0") == Self.sampleCookie)
        #expect(Self.cookie(in: any, display: "unix:3") == Self.sampleCookie)
    }

    @Test("only an MIT-MAGIC-COOKIE-1 entry is taken, and the first that matches")
    func cookieScheme() {
        let xdm = Self.entry(
            family: XAuthority.familyWild, address: "", number: "0", name: "XDM-AUTHORIZATION-1")
        let later = Self.entry(family: XAuthority.familyWild, address: "", number: "0", data: [9, 9])
        #expect(Self.cookie(in: xdm) == nil)
        #expect(
            Self.cookie(in: xdm + Self.entry(family: XAuthority.familyWild, address: "", number: "0") + later)
                == Self.sampleCookie)
    }

    @Test("a truncated entry ends the file, keeping the whole ones before it")
    func truncated() {
        let whole = Self.entry(family: XAuthority.familyLocal, address: "deck", number: "0")
        let cut = Array(Self.entry(family: XAuthority.familyWild, address: "", number: "0").dropLast(3))
        #expect(XAuthority.entries(in: whole + cut).count == 1)
        #expect(XAuthority.entries(in: [0x01]).isEmpty)
    }

    @Test("a display reached over TCP, or no display at all, has no local number")
    func remoteDisplay() {
        #expect(XAuthority.displayNumber(of: ":0") == "0")
        #expect(XAuthority.displayNumber(of: ":12.1") == "12")
        #expect(XAuthority.displayNumber(of: "unix:2") == "2")
        #expect(XAuthority.displayNumber(of: "localhost:10.0") == nil)
        #expect(XAuthority.displayNumber(of: ":") == nil)
        #expect(XAuthority.displayNumber(of: "wayland-0") == nil)
    }

    @Test("without a readable file or a local display, Xlib is left alone")
    func adoptDeclines() {
        #expect(!XAuthority.adopt(from: ["DISPLAY": ":0"]))
        #expect(!XAuthority.adopt(from: ["DISPLAY": ":0", "XAUTHORITY": "/nonexistent/skrepka-xauth"]))
        #expect(!XAuthority.adopt(from: ["DISPLAY": "remote:0", "XAUTHORITY": "/nonexistent/skrepka-xauth"]))
    }
}

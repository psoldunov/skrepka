import CX11
import Foundation

#if canImport(Glibc)
    import Glibc
#endif

/// The X authorization cookie for a local display, read from an Xauthority
/// file and handed to Xlib.
///
/// ## Why the daemon reads the file itself
///
/// Xlib finds its cookie through libXau, which opens the file the *process's*
/// `XAUTHORITY` names (`getenv`), or `~/.Xauthority` without one. A daemon that
/// learnt its display from the systemd user manager — see
/// ``UserManagerEnvironment`` — holds the manager's `XAUTHORITY` in a
/// dictionary, not in its environment, and SDDM keeps an X11 session's cookie
/// in `/tmp/xauth_XXXXXX` rather than in `~/.Xauthority` (0.21,
/// `UserSession::start`). So that daemon would find the display and then be
/// refused by it.
///
/// `setenv` is no answer in a process that already runs threads.
/// `XSetAuthorization` is: libX11 hands what it was given to
/// `xcb_connect_to_display_with_auth_info` for every later `XOpenDisplay` in
/// the process (libX11 `src/xcb_disp.c`, `_XConnectXCB`; declared in the 1.8.9
/// `Xlib.h` the build image carries).
///
/// Matching follows `XauGetBestAuthByAddr` as libxcb calls it for a Unix-socket
/// display: family `FamilyLocal` with this host's `gethostname`, or
/// `FamilyWild`; the display number equal, or empty in the entry; and only
/// `MIT-MAGIC-COOKIE-1`, the one scheme that is a plain cookie. The file format
/// is libXau's `XauReadAuth`: a big-endian `UInt16` family, then address,
/// number, name and data, each a big-endian `UInt16` length and that many bytes.
public enum XAuthority {
    struct Entry: Equatable {
        let family: UInt16
        let address: [UInt8]
        /// Bytes, compared as bytes, as `XauGetBestAuthByAddr` compares them.
        let number: [UInt8]
        let name: [UInt8]
        let data: [UInt8]
    }

    static let familyLocal: UInt16 = 256
    static let familyWild: UInt16 = 65535
    static let cookieName = "MIT-MAGIC-COOKIE-1"

    /// Hands Xlib the cookie `environment`'s `XAUTHORITY` holds for its
    /// `DISPLAY`, for every connection this process opens from now on.
    ///
    /// - Returns: whether a cookie was found and handed over. False leaves
    ///   Xlib on its own lookup, which is right for a remote display, for a
    ///   file that holds nothing for this one, and for a file that cannot be
    ///   read — Xlib would be refused by the display either way, and the probe
    ///   that follows is what says so.
    @discardableResult
    public static func adopt(from environment: [String: String]) -> Bool {
        guard let path = environment["XAUTHORITY"], !path.isEmpty,
            let display = environment["DISPLAY"], let number = displayNumber(of: display),
            let hostname = hostname(),
            let contents = FileManager.default.contents(atPath: path),
            let cookie = cookie(in: entries(in: Array(contents)), number: number, hostname: hostname)
        else { return false }
        var name = Array(cookieName.utf8).map { CChar(bitPattern: $0) }
        var data = cookie.map { CChar(bitPattern: $0) }
        name.withUnsafeMutableBufferPointer { namePointer in
            data.withUnsafeMutableBufferPointer { dataPointer in
                // Copied, not kept: libX11 allocates its own copy of both.
                XSetAuthorization(
                    namePointer.baseAddress,
                    Int32(namePointer.count),
                    dataPointer.baseAddress,
                    Int32(dataPointer.count)
                )
            }
        }
        return true
    }

    /// The display number of a local `DISPLAY` — `:0`, `:0.0`, `unix:1` — or
    /// nil for one reached over TCP, whose cookie is filed under a network
    /// address this does not match.
    static func displayNumber(of display: String) -> String? {
        guard let colon = display.lastIndex(of: ":") else { return nil }
        let host = display[..<colon]
        guard host.isEmpty || host == "unix" else { return nil }
        let number = display[display.index(after: colon)...].prefix { $0 != "." }
        guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return String(number)
    }

    /// The first cookie in `entries` for display `number` on `hostname`, or nil.
    static func cookie(in entries: [Entry], number: String, hostname: String) -> [UInt8]? {
        let address = Array(hostname.utf8)
        let display = Array(number.utf8)
        let scheme = Array(cookieName.utf8)
        let match = entries.first { entry in
            let isThisHost =
                entry.family == familyWild || (entry.family == familyLocal && entry.address == address)
            let isThisDisplay = entry.number.isEmpty || entry.number == display
            return isThisHost && isThisDisplay && entry.name == scheme && !entry.data.isEmpty
        }
        return match?.data
    }

    /// Every whole entry in `bytes`, in file order. A truncated entry ends the
    /// list, as it ends `XauReadAuth`'s.
    static func entries(in bytes: [UInt8]) -> [Entry] {
        var cursor = Cursor(bytes: bytes)
        var found: [Entry] = []
        while let entry = cursor.entry() { found.append(entry) }
        return found
    }

    /// This host's name as `gethostname` gives it — what libxcb matches a
    /// `FamilyLocal` entry against. Not `ProcessInfo.hostName`, which may be a
    /// resolved name the file does not use.
    static func hostname() -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return bytes.isEmpty ? nil : String(bytes: bytes, encoding: .utf8)
    }

    /// Reads `XauReadAuth`'s fields front to back.
    private struct Cursor {
        let bytes: [UInt8]
        var offset = 0

        mutating func entry() -> Entry? {
            guard let family = short(), let address = counted(), let number = counted(),
                let name = counted(), let data = counted()
            else { return nil }
            return Entry(family: family, address: address, number: number, name: name, data: data)
        }

        private mutating func short() -> UInt16? {
            guard offset + 2 <= bytes.count else { return nil }
            defer { offset += 2 }
            return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        }

        private mutating func counted() -> [UInt8]? {
            guard let length = short().map(Int.init), offset + length <= bytes.count else { return nil }
            defer { offset += length }
            return Array(bytes[offset..<offset + length])
        }
    }
}

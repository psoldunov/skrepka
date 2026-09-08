import CX11
import Foundation

/// Whether an X11 display will actually accept a connection, and whether it
/// carries the extension the backend needs.
///
/// `DISPLAY` being set proves nothing — it survives in the environment of a
/// process whose server has gone, and it is set inside a Wayland session for
/// XWayland's benefit whether or not XWayland is running. ``SessionProbe`` only
/// believes the variable once this has opened a connection against it.
enum XDisplayProbe {
    /// Opens a connection, checks for XFIXES, and closes it again.
    ///
    /// XFIXES is checked rather than assumed: without it there is no
    /// `XFixesSelectSelectionInput`, the backend has no way to learn that a
    /// selection changed, and it would have to poll `XGetSelectionOwner` —
    /// which is not what this backend is. A server without it is a server this
    /// backend cannot use, so it is not a display worth choosing.
    ///
    /// The extension has shipped in every X.Org release since 2003, so this
    /// returning false is nearly always a display that is simply not there.
    static func canConnect(_ displayName: String?) -> Bool {
        guard let display = XOpenDisplay(displayName) else { return false }
        defer { XCloseDisplay(display) }
        var eventBase: Int32 = 0
        var errorBase: Int32 = 0
        return XFixesQueryExtension(display, &eventBase, &errorBase) != 0
    }
}

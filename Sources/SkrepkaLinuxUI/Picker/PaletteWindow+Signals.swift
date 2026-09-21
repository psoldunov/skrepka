import CGtk4
import SkrepkaCore

// The C side of ``PaletteWindow``: the one key callback GTK reaches through a
// function pointer, and the retain it balances.
//
// Split from the window itself because it is the only part that is not ordinary
// Swift — `nonisolated`, reconstructing the window from an opaque pointer, and
// making no claim the compiler could check. The search field owns its own
// `changed` signal now, so the window listens for keys alone.
extension PaletteWindow {

    private static func palette(from data: gpointer?) -> PaletteWindow? {
        guard let data else { return nil }
        return Unmanaged<PaletteWindow>.fromOpaque(data).takeUnretainedValue()
    }

    /// Returns 1 to stop the key here, 0 to let it reach the search field.
    ///
    /// `keycode` is passed on rather than dropped: it is the only
    /// layout-independent name for a key, and Alt+1–9 needs one — see
    /// ``PickerKeyMap``.
    static func keyPressed(
        _ controller: OpaquePointer?,
        keysym: UInt32,
        keycode: UInt32,
        state: UInt32,
        data: gpointer?
    ) -> gboolean {
        guard let palette = palette(from: data) else { return 0 }
        palette.recordModifiers(state)
        let command = PickerKeyMap.command(
            keysym: keysym,
            keycode: keycode,
            modifiers: PickerModifiers(rawValue: state),
            pageJump: PaletteWindow.pageJump)
        guard command != .type else { return 0 }
        palette.onCommand?(command)
        return 1
    }

    /// Formed from a literal closure rather than a bare reference for the reason
    /// the Linux compiler gives: a C function pointer can only come from a
    /// literal closure or a `func` reference it happens to accept, and the
    /// closure with positional `$0` is what compiles for both.
    static let onKeyPressed: @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean =
        {
            keyPressed($0, keysym: $1, keycode: $2, state: $3, data: $4)
        }

    static let onModifiersChanged: @convention(c) (OpaquePointer?, UInt32, gpointer?) -> gboolean = {
        guard let palette = palette(from: $2) else { return 0 }
        palette.recordModifiers($1)
        return 0
    }

    /// Drops the retain ``connectKeys(_:)`` took, when GLib destroys the
    /// closure — the only moment releasing is neither too early nor never.
    static let onContextReleased: GClosureNotify = { data, _ in
        guard let data else { return }
        Unmanaged<PaletteWindow>.fromOpaque(data).release()
    }
}

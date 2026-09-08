import CGtk4
import SkrepkaCore

// The C side of ``PaletteWindow``: the four declarations that exist only
// because GTK calls back into Swift through function pointers.
//
// Split from the window itself rather than sitting at the bottom of it. They
// are the only part of the palette that is not ordinary Swift — each one is
// `nonisolated`, reconstructs the window from an opaque pointer, and makes no
// claim the compiler could check — so they are worth reading as a group rather
// than finding one at a time.
extension PaletteWindow {

    private static func palette(from data: gpointer?) -> PaletteWindow? {
        guard let data else { return nil }
        return Unmanaged<PaletteWindow>.fromOpaque(data).takeUnretainedValue()
    }

    /// Returns 1 to stop the key here, 0 to let it reach the search field.
    ///
    /// Spelled as a function referenced by a `@convention(c)` constant rather
    /// than as an inline closure: the signature is five parameters wide, and as
    /// a closure it can only be written with the parameter list on its own line,
    /// which the linter refuses and which reads worse anyway. A C function
    /// pointer can be formed from any function that captures nothing, and this
    /// captures nothing — everything it needs arrives in `data`.
    static func keyPressed(
        _ controller: OpaquePointer?,
        keysym: UInt32,
        keycode: UInt32,
        state: UInt32,
        data: gpointer?
    ) -> gboolean {
        guard let palette = palette(from: data) else { return 0 }
        // `keycode` is passed on rather than dropped: it is the only
        // layout-independent name for a key, and Alt+1–9 needs one. See
        // ``PickerKeyMap/rowIndex(keysym:keycode:)``.
        let command = PickerKeyMap.command(
            keysym: keysym,
            keycode: keycode,
            modifiers: PickerModifiers(rawValue: state),
            pageJump: PaletteWindow.pageJump
        )
        guard command != .type else { return 0 }
        palette.onCommand?(command)
        return 1
    }

    static func searchChanged(_ editable: OpaquePointer?, data: gpointer?) {
        guard let palette = palette(from: data) else { return }
        palette.onQueryChanged?(palette.query)
    }

    // Literal closures that forward to the functions above, rather than bare
    // references to them. A bare reference works for one of the two and not the
    // other — `= searchChanged` is rejected with "a C function pointer can only
    // be formed from a reference to a 'func' or a literal closure", on Linux,
    // for a declaration that is a `func` — so both are spelled the way that
    // compiles. Positional `$0` also sidesteps the parameter list that made
    // these closures unformattable in the first place.
    static let onKeyPressed: @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean =
        {
            keyPressed($0, keysym: $1, keycode: $2, state: $3, data: $4)
        }

    static let onSearchChanged: @convention(c) (OpaquePointer?, gpointer?) -> Void = {
        searchChanged($0, data: $1)
    }

    /// Drops one of the retains ``PaletteWindow/connectSignals(keys:)`` took.
    ///
    /// GLib calls this once per closure it destroys, which is when GTK has
    /// finished with the widget the handler was on — the only moment at which
    /// releasing is neither too early nor never. One notify per connection
    /// balances one `passRetained` per connection; the palette dies with the
    /// last of them.
    static let onContextReleased: GClosureNotify = { data, _ in
        guard let data else { return }
        Unmanaged<PaletteWindow>.fromOpaque(data).release()
    }
}

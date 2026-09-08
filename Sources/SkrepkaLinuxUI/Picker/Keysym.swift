/// The X11 keysyms the picker reacts to, and the modifier bits that come with
/// them.
///
/// Spelled out rather than imported from GDK, for two reasons. The `GDK_KEY_*`
/// names are object-like macros, and a Swift build that stopped importing them
/// would silently fall back to matching nothing — which reads as "the
/// compositor ate the key" rather than as a build problem. And keeping them
/// here is what lets ``PickerCommand`` be decided without GTK in scope, so the
/// decision is testable without a display.
///
/// Values verified against `/usr/include/gtk-4.0/gdk/gdkkeysyms.h` and
/// `gdkenums.h` in the Linux build image (GTK 4.14.5), not from memory. The
/// keysym numbers are X11's and have not changed since X11R6; the modifier bits
/// are GDK's own and are the ones that arrive in a `key-pressed` signal.
public enum Keysym {
    public static let escape: UInt32 = 0xff1b
    public static let enter: UInt32 = 0xff0d
    public static let keypadEnter: UInt32 = 0xff8d
    public static let up: UInt32 = 0xff52
    public static let down: UInt32 = 0xff54
    public static let pageUp: UInt32 = 0xff55
    public static let pageDown: UInt32 = 0xff56
    public static let home: UInt32 = 0xff50
    public static let end: UInt32 = 0xff57
    /// ASCII, and the range the by-number shortcuts read.
    public static let one: UInt32 = 0x0031
    public static let nine: UInt32 = 0x0039
    public static let lowercaseP: UInt32 = 0x0070
    public static let uppercaseP: UInt32 = 0x0050

    /// The hardware keycodes of the number row, `1` through `9`.
    ///
    /// Keycodes, not keysyms, and that is the point of having them: a keysym is
    /// what a key produces under the user's layout, and the number row produces
    /// `&é"'(-è_ç` on AZERTY. A keycode is the key itself and does not move.
    ///
    /// 10 through 18 because Linux's input layer numbers these keys `KEY_1` …
    /// `KEY_9` = 2 … 10, and both display protocols report a number eight
    /// higher: X11 reserves keycodes below 8, and Wayland's `wl_keyboard`
    /// specifies its `key` events as carrying the XKB keycode rather than the
    /// evdev one, so it inherited the same offset. GTK passes that number
    /// through untouched as the `key-pressed` signal's `keycode`.
    public static let digitRow: ClosedRange<UInt32> = 10...18
}

/// The modifier bits GDK reports alongside a key press.
///
/// Raw values are `GdkModifierType`'s, from `gdkenums.h` lines 126–129, so a
/// caller passes the mask straight through from the `key-pressed` signal
/// without a translation table in between. Only the three the picker reads are
/// declared — a bit this type does not name is a bit the picker ignores, which
/// is deliberate: Lock and the button masks arrive in the same word and must
/// not turn Return into something else.
public struct PickerModifiers: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let shift = PickerModifiers(rawValue: 1 << 0)
    public static let control = PickerModifiers(rawValue: 1 << 2)
    /// `GDK_ALT_MASK`. Alt is Linux's ⌘ for this picker — see ``PickerCommand``.
    public static let alt = PickerModifiers(rawValue: 1 << 3)
}

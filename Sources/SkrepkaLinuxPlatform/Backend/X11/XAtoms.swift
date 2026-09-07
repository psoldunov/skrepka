import CXFixesShim
import Foundation

/// X11 constants Swift imports at the wrong width.
///
/// `None` is `#define None 0L`, so it arrives as `Int` while every `Atom`,
/// `Window` and `XID` it is compared against is `UInt`. Spelling the conversion
/// once here beats twelve `Atom(None)` casts, each of which is a place to write
/// `0` by accident and mean something else.
enum X11 {
    /// No atom, no window, no property — the refusal ICCCM replies with.
    static let none: UInt = 0
    /// `AnyPropertyType`, which is also `0L` and also arrives as `Int`.
    /// Spelled apart from ``none`` because they mean different things at the
    /// same value, and a reader should not have to know they collide.
    static let anyPropertyType: Atom = 0
}

/// The atoms the X11 backend names, interned once per connection.
///
/// Interning is a server round trip, and the read path names half a dozen of
/// these per clipboard change. Doing it once at connect turns that into a
/// dictionary lookup.
///
/// Only three atoms in all of X11 are predefined — verified against the
/// installed `/usr/include/X11/Xatom.h`, which defines `XA_ATOM` as 4,
/// `XA_INTEGER` as 19 and `XA_STRING` as 31. `CLIPBOARD`, `TARGETS`, `INCR`
/// and the rest are ordinary interned names despite reading like constants.
struct XAtoms {
    /// The selection a clipboard manager watches. `PRIMARY` is the
    /// middle-click selection and is deliberately not here: it changes on every
    /// drag through a text field, and recording it would fill history with
    /// fragments nobody asked to keep.
    let clipboard: Atom
    /// ICCCM §2.6.2's three required targets. An owner that does not answer all
    /// three is not conforming, whatever else it does.
    let targets: Atom
    let timestamp: Atom
    let multiple: Atom
    /// Type of a reply that will arrive in pieces — ICCCM §2.7.2.
    let incr: Atom
    /// `ATOM_PAIR`, the type of a `MULTIPLE` request's property.
    let atomPair: Atom
    /// The property Skrepka asks owners to put replies on, on its own window.
    let transferProperty: Atom
    /// UTF-8 text, which is what every toolkit written since 2000 offers.
    let utf8String: Atom
    /// Used to provoke a `PropertyNotify` and read a server timestamp off it.
    let timeProperty: Atom

    init(display: OpaquePointer) {
        func intern(_ name: String) -> Atom {
            XInternAtom(display, name, 0)
        }
        clipboard = intern("CLIPBOARD")
        targets = intern("TARGETS")
        timestamp = intern("TIMESTAMP")
        multiple = intern("MULTIPLE")
        incr = intern("INCR")
        atomPair = intern("ATOM_PAIR")
        transferProperty = intern("SKREPKA_SELECTION")
        utf8String = intern("UTF8_STRING")
        timeProperty = intern("SKREPKA_TIME")
    }

    /// The name the mapping layer knows a target atom by.
    ///
    /// `XGetAtomName` allocates, so the result is copied and freed here rather
    /// than handed out as a C string nobody would remember to release.
    static func name(of atom: Atom, display: OpaquePointer) -> String? {
        guard let raw = XGetAtomName(display, atom) else { return nil }
        defer { XFree(raw) }
        return String(cString: raw)
    }
}

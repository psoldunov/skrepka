/// The colours the picker and the Settings window draw in, for one mode.
///
/// One table for both windows, so they read as one product: the Settings
/// window's cards are the picker's tiles, its hairlines are the picker's, and
/// its selected sidebar row is the picker's selected row. Every colour is a
/// literal `rgba()` resolved for the mode, not `currentColor` — GTK does not
/// carry `currentColor` through alpha the way a browser does.
struct SkrepkaPalette {
    // MARK: The picker's

    let panel: String
    let border: String
    let hairline: String
    let primary: String
    let secondary: String
    let tertiary: String
    let tile: String
    let badge: String
    /// The wide, soft half of the overlay's two-layer shadow.
    let shadowFar: String
    /// The tight half, which seats the panel on the desktop. Also the plain
    /// window's whole shadow.
    let shadowNear: String

    // MARK: The Settings window's

    /// The window behind everything: the picker's panel, opaque. A toplevel
    /// is not composited over a blur the way the picker's surface can be, so
    /// a translucent one would show whatever window happens to be behind it.
    let window: String
    /// The sidebar's wash over ``window``.
    let sidebar: String
    /// A card of rows.
    let card: String
    /// A button, a drop-down, a switch's track while it is off.
    let control: String
    let controlHover: String
    /// A switch's knob.
    let knob: String

    static let dark = SkrepkaPalette(
        panel: "rgba(28,28,30,0.92)",
        border: "rgba(255,255,255,0.12)",
        hairline: "rgba(255,255,255,0.11)",
        primary: "rgba(255,255,255,0.92)",
        secondary: "rgba(255,255,255,0.55)",
        tertiary: "rgba(255,255,255,0.35)",
        tile: "rgba(255,255,255,0.09)",
        badge: "rgba(255,255,255,0.09)",
        shadowFar: "rgba(0,0,0,0.42)",
        shadowNear: "rgba(0,0,0,0.30)",
        window: "rgb(28,28,30)",
        sidebar: "rgba(255,255,255,0.035)",
        card: "rgba(255,255,255,0.06)",
        control: "rgba(255,255,255,0.13)",
        controlHover: "rgba(255,255,255,0.19)",
        knob: "rgb(255,255,255)"
    )

    static let light = SkrepkaPalette(
        panel: "rgba(246,246,248,0.94)",
        border: "rgba(0,0,0,0.12)",
        hairline: "rgba(0,0,0,0.10)",
        primary: "rgba(0,0,0,0.88)",
        secondary: "rgba(0,0,0,0.55)",
        tertiary: "rgba(0,0,0,0.38)",
        tile: "rgba(0,0,0,0.06)",
        badge: "rgba(0,0,0,0.06)",
        shadowFar: "rgba(0,0,0,0.22)",
        shadowNear: "rgba(0,0,0,0.14)",
        window: "rgb(240,240,243)",
        sidebar: "rgba(0,0,0,0.035)",
        card: "rgb(255,255,255)",
        control: "rgba(0,0,0,0.08)",
        controlHover: "rgba(0,0,0,0.12)",
        knob: "rgb(255,255,255)"
    )

    static func forMode(isDark: Bool) -> SkrepkaPalette {
        isDark ? dark : light
    }

    /// The macOS-blue default, for a desktop that names no accent.
    static let defaultAccent = "rgb(10,122,255)"
}

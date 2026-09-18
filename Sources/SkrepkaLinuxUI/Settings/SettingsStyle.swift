import CGtk4

/// The Settings window's few style rules, installed once for the display.
///
/// Deliberately small and theme-neutral. The Steam Deck runs KDE, whose GTK
/// theme is Breeze rather than Adwaita, so nothing here names a colour a theme
/// defines or a style class only one theme ships: sizes, weights and
/// transparency over `currentColor` read the same in both, light or dark.
/// Spacing is set on the widgets themselves, where every theme honours it.
enum SettingsStyle {
    static let heading = "skrepka-heading"
    static let secondary = "skrepka-secondary"
    static let code = "skrepka-code"
    static let monospace = "skrepka-mono"
    static let banner = "skrepka-banner"
    static let bannerMessage = "skrepka-banner-message"
    static let dialogTitle = "skrepka-dialog-title"

    static let css = """
        .skrepka-heading { font-weight: bold; }
        .skrepka-secondary { opacity: 0.7; font-size: smaller; }
        .skrepka-mono { font-family: monospace; }
        .skrepka-code { font-family: monospace; font-size: 20pt; font-weight: bold; letter-spacing: 1px; }
        .skrepka-banner {
            padding: 10px 12px;
            border-radius: 8px;
            border: 1px solid alpha(currentColor, 0.2);
            background-color: alpha(currentColor, 0.05);
        }
        .skrepka-banner-message { font-weight: bold; }
        .skrepka-dialog-title { font-weight: bold; font-size: larger; }
        """

    /// Adds the rules to the default display. Call after GTK has opened it.
    static func install() {
        skrepka_install_css(css)
    }
}

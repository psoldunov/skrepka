/// The Settings window's stylesheet: the picker's palette, accent and
/// hairlines, laid out as a sidebar and cards of rows.
///
/// Every selector is scoped to `window.skrepka-settings` or a `skrepka-` class,
/// so installing it on the shared display restyles nothing else — not the
/// picker, whose own stylesheet sits in a slot of its own. Controls GTK's
/// theme draws (switches, buttons, drop-downs, the title bar) are restyled
/// only inside the Settings window, because the Steam Deck's theme is
/// Breeze-GTK and a settings window drawn half in Breeze and half in the
/// picker's colours reads as two products.
enum SettingsStyle {
    // MARK: Classes

    static let window = "skrepka-settings"
    static let titlebar = "skrepka-titlebar"
    static let sidebar = "skrepka-sidebar"
    static let identity = "skrepka-identity"
    static let identityName = "skrepka-identity-name"
    static let identityVersion = "skrepka-identity-version"
    static let nav = "skrepka-nav"
    static let page = "skrepka-page"
    static let pageTitle = "skrepka-page-title"
    static let heading = "skrepka-card-title"
    static let card = "skrepka-card"
    static let footer = "skrepka-card-footer"
    static let row = "skrepka-row"
    /// A read-only fact, which needs no finger-sized target.
    static let compactRow = "skrepka-row-compact"
    static let deviceList = "skrepka-devices"
    static let rowTitle = "skrepka-row-title"
    static let secondary = "skrepka-secondary"
    static let rowIcon = "skrepka-row-icon"
    static let value = "skrepka-value"
    static let monospace = "skrepka-mono"
    static let keycap = "skrepka-settings-keycap"
    static let metric = "skrepka-metric"
    static let metricValue = "skrepka-metric-value"
    static let metricLabel = "skrepka-metric-label"
    static let dot = "skrepka-dot"
    static let banner = "skrepka-banner"
    static let bannerMessage = "skrepka-banner-message"
    static let destructive = "skrepka-destructive"
    static let suggested = "skrepka-suggested"
    static let code = "skrepka-code"
    static let dialogTitle = "skrepka-dialog-title"

    /// The class a tone adds to a banner or a status dot.
    static func tone(_ tone: SyncNotice.Tone) -> String {
        switch tone {
        case .problem: "skrepka-tone-problem"
        case .success: "skrepka-tone-good"
        case .info: "skrepka-tone-info"
        }
    }

    static func tone(_ tone: DiagnosticsPaneState.Tone) -> String {
        switch tone {
        case .good: "skrepka-tone-good"
        case .warning: "skrepka-tone-warning"
        case .bad: "skrepka-tone-problem"
        }
    }

    static let allTones = [
        "skrepka-tone-problem", "skrepka-tone-good", "skrepka-tone-info", "skrepka-tone-warning",
    ]

    // MARK: Installing

    /// Installs the stylesheet for `appearance` on the default display,
    /// replacing the one installed before.
    static func apply(_ appearance: AppearancePreference) {
        CssInstaller.install(
            css(isDark: appearance.resolvesDark, accent: appearance.accentCSS), slot: .settings)
    }

    /// The whole stylesheet, as one string.
    static func css(isDark: Bool, accent: String) -> String {
        let palette = SkrepkaPalette.forMode(isDark: isDark)
        let tones = Tones(isDark: isDark)
        return [
            chrome(palette, accent: accent),
            sidebar(palette, accent: accent),
            content(palette),
            status(palette, tones: tones),
            controls(palette, accent: accent, tones: tones),
            popovers(palette, accent: accent, isDark: isDark),
        ].joined(separator: "\n")
    }

    /// The status colours: Apple's system red, orange and green, in
    /// their dark or light variants, as the Mac's Settings draws them.
    struct Tones {
        let red: String
        let orange: String
        let green: String

        init(isDark: Bool) {
            red = isDark ? "rgb(255,69,58)" : "rgb(215,0,21)"
            orange = isDark ? "rgb(255,159,10)" : "rgb(201,52,0)"
            green = isDark ? "rgb(48,209,88)" : "rgb(36,138,61)"
        }
    }
}

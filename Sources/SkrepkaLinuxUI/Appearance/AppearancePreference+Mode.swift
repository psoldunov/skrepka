import CGtk4

// MARK: - Resolving the preference

extension AppearancePreference {
    /// Dark or light, asking GTK's own setting when the desktop states no
    /// preference — the rule the picker follows, so the two windows never
    /// disagree.
    var resolvesDark: Bool {
        switch colorScheme {
        case .dark: true
        case .light: false
        case .noPreference: skrepka_prefers_dark() != 0
        }
    }

    /// The accent as GTK CSS, or the macOS blue when the desktop names none.
    var accentCSS: String {
        accent?.cssValue ?? SkrepkaPalette.defaultAccent
    }
}

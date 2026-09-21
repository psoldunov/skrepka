import CGtk4
import SkrepkaCore

/// The picker's stylesheet, generated for a dark or light desktop and an accent
/// colour, and installed above the theme.
///
/// One GTK CSS string rather than per-widget property calls: the macOS picker's
/// look is a Spotlight-style single glass panel, and expressing 20px radii,
/// hairlines and an 8px accent selection as code would bury the design in
/// pointer casts. Every selector is scoped to a `skrepka-` class or the
/// picker's own window, so installing it on the shared display — the Settings
/// window lives in the same process — restyles nothing else.
///
/// GTK CSS is not the browser's: there is no `backdrop-filter`, so the
/// translucency is a semi-transparent panel colour over the compositor's own
/// blur where it has one, and a flat wash where it does not. Colours are
/// resolved here into literal `rgba()` for the mode rather than left to
/// `currentColor`, which GTK does not carry through alpha the way a browser
/// does.
enum PickerStyle {
    /// The colours one mode draws in.
    private struct Palette {
        let panel: String
        let border: String
        let hairline: String
        let primary: String
        let secondary: String
        let tertiary: String
        let tile: String
        let badge: String
        let shadow: String
    }

    private static let dark = Palette(
        panel: "rgba(28,28,30,0.92)",
        border: "rgba(255,255,255,0.12)",
        hairline: "rgba(255,255,255,0.11)",
        primary: "rgba(255,255,255,0.92)",
        secondary: "rgba(255,255,255,0.55)",
        tertiary: "rgba(255,255,255,0.35)",
        tile: "rgba(255,255,255,0.09)",
        badge: "rgba(255,255,255,0.09)",
        shadow: "rgba(0,0,0,0.55)"
    )

    private static let light = Palette(
        panel: "rgba(246,246,248,0.94)",
        border: "rgba(0,0,0,0.12)",
        hairline: "rgba(0,0,0,0.10)",
        primary: "rgba(0,0,0,0.88)",
        secondary: "rgba(0,0,0,0.55)",
        tertiary: "rgba(0,0,0,0.38)",
        tile: "rgba(0,0,0,0.06)",
        badge: "rgba(0,0,0,0.06)",
        shadow: "rgba(0,0,0,0.30)"
    )

    /// The macOS-blue default, for a desktop that names no accent.
    static let defaultAccent = "rgb(10,122,255)"

    /// Installs the stylesheet for `appearance` on the default display.
    static func apply(_ appearance: AppearancePreference, isDark: Bool) {
        skrepka_install_css(css(isDark: isDark, accent: appearance.accent?.cssValue ?? defaultAccent))
    }

    /// The whole stylesheet, as one string.
    static func css(isDark: Bool, accent: String) -> String {
        let palette = isDark ? dark : light
        return [
            window(palette),
            search(palette),
            list(palette, accent: accent),
            footer(palette),
            empty(palette),
        ].joined(separator: "\n")
    }

    private static func window(_ palette: Palette) -> String {
        """
        window.skrepka-picker { background: transparent; }
        .skrepka-panel {
          background: \(palette.panel);
          border: 0.5px solid \(palette.border);
          border-radius: 20px;
          margin: 22px;
          box-shadow: 0 14px 40px \(palette.shadow);
        }
        .skrepka-hairline { background: \(palette.hairline); min-height: 1px; }
        """
    }

    private static func search(_ palette: Palette) -> String {
        """
        .skrepka-search { padding: 0 16px; }
        .skrepka-search image { color: \(palette.secondary); -gtk-icon-size: 16px; }
        .skrepka-search-entry {
          background: none; border: none; box-shadow: none; outline: none;
          padding: 0; caret-color: \(accentCaret); font-size: 17px; color: \(palette.primary);
        }
        .skrepka-search-entry text { background: none; }
        .skrepka-search-entry > placeholder { color: \(palette.tertiary); }
        .skrepka-search-count { color: \(palette.secondary); font-size: 12px; font-weight: 500; }
        .skrepka-search-clear { background: none; border: none; box-shadow: none;
          min-height: 20px; min-width: 20px; padding: 0; color: \(palette.tertiary); }
        .skrepka-search-clear:hover { color: \(palette.secondary); }
        """
    }

    /// The caret uses the primary text colour rather than the accent so it does
    /// not fight the accent selection fill for attention.
    private static let accentCaret = "currentColor"

    private static func list(_ palette: Palette, accent: String) -> String {
        """
        .skrepka-list { background: none; padding: 6px 8px; }
        .skrepka-list > row { padding: 0; background: none; }
        .skrepka-list > row:selected { background: none; box-shadow: none; }
        .skrepka-rowbody { padding: 0 10px; margin: 1px 0; border-radius: 8px; }
        .skrepka-list > row:selected .skrepka-rowbody { background: \(accent); }
        .skrepka-tile {
          background: \(palette.tile); border-radius: 6px;
          border: 0.5px solid \(palette.hairline); color: \(palette.secondary);
        }
        .skrepka-tile image { color: \(palette.secondary); -gtk-icon-size: 15px; }
        .skrepka-thumb { border-radius: 6px; border: 0.5px solid \(palette.hairline); }
        .skrepka-title { font-size: 13px; color: \(palette.primary); }
        .skrepka-subtitle { font-size: 11px; color: \(palette.secondary); }
        .skrepka-pin { color: \(palette.secondary); -gtk-icon-size: 12px; }
        .skrepka-badge {
          font-size: 10px; font-weight: 500; color: \(palette.tertiary);
          background: \(palette.badge); border-radius: 5px; padding: 1px 5px;
        }
        .skrepka-list > row:selected .skrepka-title,
        .skrepka-list > row:selected .skrepka-tile image,
        .skrepka-list > row:selected .skrepka-pin { color: #ffffff; }
        .skrepka-list > row:selected .skrepka-subtitle { color: rgba(255,255,255,0.75); }
        .skrepka-list > row:selected .skrepka-badge {
          color: rgba(255,255,255,0.85); background: rgba(255,255,255,0.16);
        }
        """
    }

    private static func footer(_ palette: Palette) -> String {
        """
        .skrepka-footer { padding: 0 14px; }
        .skrepka-hint { font-size: 11px; color: \(palette.secondary); }
        .skrepka-keycap {
          font-size: 10px; font-weight: 600; color: \(palette.secondary);
          background: \(palette.badge); border-radius: 4px;
          border: 0.5px solid \(palette.hairline); padding: 1px 5px; min-width: 14px;
        }
        .skrepka-error { font-size: 11px; color: \(palette.primary); }
        .skrepka-gear {
          background: none; border: none; box-shadow: none; padding: 4px;
          min-height: 22px; min-width: 22px; color: \(palette.secondary);
        }
        .skrepka-gear:hover { color: \(palette.primary); }
        """
    }

    private static func empty(_ palette: Palette) -> String {
        """
        .skrepka-empty { color: \(palette.tertiary); }
        .skrepka-empty-title { font-size: 14px; font-weight: 500; color: \(palette.secondary); }
        .skrepka-empty-detail { font-size: 12px; color: \(palette.tertiary); }
        .skrepka-empty image { color: \(palette.tertiary); -gtk-icon-size: 30px; }
        .skrepka-empty-warn image { color: #ff9f0a; }
        """
    }
}

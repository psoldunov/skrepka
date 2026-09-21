// MARK: - Window, sidebar, pages and cards

// The window buttons are drawn from the icon theme's `window-*-symbolic` icons,
// in the palette's colours, whatever GTK theme is installed. That takes two
// explicit rules rather than one `background: none`: Breeze-GTK — KDE's GTK
// theme, and so the Steam Deck's — paints its buttons as `background-image`
// assets and sets the button's icon to `color: transparent`. Clearing the
// background removed Breeze's picture and left its transparent icon, so the
// buttons vanished; `background-image: none` plus an opaque icon colour gives
// the same buttons under Breeze and Adwaita.
extension SettingsStyle {
    static func chrome(_ palette: SkrepkaPalette, accent: String) -> String {
        """
        window.skrepka-settings { background: \(palette.window); color: \(palette.primary); font-size: 13px; }
        window.skrepka-settings headerbar {
          background: \(palette.window); color: \(palette.primary);
          border: none; box-shadow: inset 0 -1px \(palette.hairline);
          min-height: 46px; padding: 0 8px;
        }
        window.skrepka-settings headerbar:backdrop { background: \(palette.window); }
        window.skrepka-settings headerbar .title { font-size: 13px; font-weight: 600; }
        window.skrepka-settings headerbar:backdrop .title { color: \(palette.secondary); }
        window.skrepka-settings windowcontrols button {
          background-color: transparent; background-image: none;
          border: none; box-shadow: none; outline: none;
          min-width: 28px; min-height: 28px; padding: 0; margin: 0 2px; border-radius: 14px;
          color: \(palette.secondary);
        }
        window.skrepka-settings windowcontrols button:hover {
          background-color: \(palette.control); background-image: none; color: \(palette.primary);
        }
        window.skrepka-settings windowcontrols button:active,
        window.skrepka-settings windowcontrols button:backdrop { background-image: none; }
        window.skrepka-settings windowcontrols button:focus-visible { box-shadow: 0 0 0 2px alpha(\(accent), 0.7); }
        window.skrepka-settings windowcontrols button image {
          color: inherit; opacity: 1; -gtk-icon-size: 14px;
        }
        window.skrepka-settings scrollbar { background: none; border: none; }
        window.skrepka-settings scrollbar slider {
          background: \(palette.tertiary); border-radius: 4px; min-width: 6px; min-height: 6px; border: none;
        }
        """
    }

    static func sidebar(_ palette: SkrepkaPalette, accent: String) -> String {
        """
        .skrepka-sidebar {
          background: \(palette.sidebar); box-shadow: inset -1px 0 \(palette.hairline);
          padding: 18px 12px; min-width: 212px;
        }
        .skrepka-identity { padding: 0 6px 18px 6px; }
        .skrepka-identity-mark { background: alpha(\(accent), 0.16); border-radius: 11px; }
        .skrepka-identity-name { font-size: 15px; font-weight: 600; color: \(palette.primary); }
        .skrepka-identity-version { font-size: 11px; color: \(palette.secondary); }
        .skrepka-nav { background: none; }
        .skrepka-nav > row {
          min-height: 48px; padding: 0 12px; margin: 2px 0; border-radius: 10px;
          background: none; color: \(palette.primary); outline: none;
        }
        .skrepka-nav > row:hover { background: \(palette.tile); }
        .skrepka-nav > row:focus-visible { box-shadow: inset 0 0 0 2px alpha(\(accent), 0.7); }
        .skrepka-nav > row:selected { background: \(accent); color: #ffffff; }
        .skrepka-nav > row:selected:focus-visible { box-shadow: inset 0 0 0 2px rgba(255,255,255,0.65); }
        .skrepka-nav > row label { font-size: 14px; }
        .skrepka-nav > row image { -gtk-icon-size: 18px; color: \(palette.secondary); }
        .skrepka-nav > row:selected image { color: #ffffff; }
        """
    }

    static func content(_ palette: SkrepkaPalette) -> String {
        """
        .skrepka-page { padding: 24px 30px 32px 30px; }
        .skrepka-page-title { font-size: 22px; font-weight: 700; color: \(palette.primary); }
        .skrepka-card-title {
          font-size: 11px; font-weight: 600; letter-spacing: 0.5px;
          color: \(palette.secondary); margin: 0 6px;
        }
        .skrepka-card {
          background: \(palette.card); border: 0.5px solid \(palette.hairline); border-radius: 12px;
        }
        .skrepka-card > separator { background: \(palette.hairline); min-height: 1px; margin-left: 14px; }
        list.skrepka-devices { background: none; }
        list.skrepka-devices > row { background: none; padding: 0; outline: none; border: none; box-shadow: none; }
        list.skrepka-devices > row:hover { background: none; }
        list.skrepka-devices > row + row { border-top: 1px solid \(palette.hairline); }
        .skrepka-card-footer { font-size: 11px; color: \(palette.tertiary); margin: 0 6px; }
        .skrepka-row { min-height: 36px; padding: 6px 14px; }
        .skrepka-row.skrepka-row-compact { min-height: 22px; padding: 9px 14px; }
        .skrepka-row-title { font-size: 13px; color: \(palette.primary); }
        .skrepka-secondary { font-size: 11px; color: \(palette.secondary); }
        .skrepka-row-icon { -gtk-icon-size: 16px; color: \(palette.secondary); min-width: 20px; }
        .skrepka-value { font-size: 13px; color: \(palette.secondary); }
        .skrepka-mono { font-family: monospace; font-size: 12px; }
        .skrepka-settings-keycap {
          font-size: 12px; font-weight: 600; color: \(palette.primary);
          background: \(palette.badge); border: 0.5px solid \(palette.hairline);
          border-radius: 6px; padding: 3px 8px; min-width: 14px;
        }
        .skrepka-metric {
          background: \(palette.card); border: 0.5px solid \(palette.hairline); border-radius: 12px;
          padding: 12px 15px;
        }
        .skrepka-metric-value {
          font-size: 25px; font-weight: 500; font-feature-settings: "tnum"; color: \(palette.primary);
        }
        .skrepka-metric-label { font-size: 11px; color: \(palette.secondary); }
        """
    }

    static func status(_ palette: SkrepkaPalette, tones: Tones) -> String {
        """
        .skrepka-dot { min-width: 10px; min-height: 10px; border-radius: 5px; background: \(palette.tertiary); }
        .skrepka-dot.skrepka-tone-good { background: \(tones.green); }
        .skrepka-dot.skrepka-tone-warning { background: \(tones.orange); }
        .skrepka-dot.skrepka-tone-problem { background: \(tones.red); }
        .skrepka-banner {
          background: \(palette.card); border: 0.5px solid \(palette.hairline); border-radius: 12px;
          padding: 12px 14px;
        }
        .skrepka-banner.skrepka-tone-problem { background: alpha(\(tones.red), 0.12); border-color: alpha(\(tones.red), 0.45); }
        .skrepka-banner.skrepka-tone-good { background: alpha(\(tones.green), 0.12); border-color: alpha(\(tones.green), 0.45); }
        .skrepka-banner-message { font-size: 13px; font-weight: 600; color: \(palette.primary); }
        .skrepka-code { font-family: monospace; font-size: 26px; font-weight: 700; letter-spacing: 1px; }
        .skrepka-dialog-title { font-size: 15px; font-weight: 700; }
        """
    }
}

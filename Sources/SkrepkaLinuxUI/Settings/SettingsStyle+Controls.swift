// MARK: - Buttons, switches and drop-downs

extension SettingsStyle {
    static func controls(_ palette: SkrepkaPalette, accent: String, tones: Tones) -> String {
        [buttons(palette, accent: accent, tones: tones), switches(palette, accent: accent)]
            .joined(separator: "\n")
    }

    private static func buttons(_ palette: SkrepkaPalette, accent: String, tones: Tones) -> String {
        """
        window.skrepka-settings button {
          background: \(palette.control); color: \(palette.primary);
          border: none; border-radius: 8px; box-shadow: none; outline: none; text-shadow: none;
          min-height: 34px; padding: 0 14px; font-weight: 500;
        }
        window.skrepka-settings button:hover { background: \(palette.controlHover); }
        window.skrepka-settings button:active { background: \(palette.controlHover); opacity: 0.85; }
        window.skrepka-settings button:disabled { opacity: 0.45; }
        window.skrepka-settings button:disabled label { color: \(palette.primary); }
        window.skrepka-settings button:focus-visible { box-shadow: 0 0 0 2px alpha(\(accent), 0.7); }
        window.skrepka-settings button.skrepka-destructive { color: \(tones.red); }
        window.skrepka-settings button.skrepka-suggested,
        window.skrepka-settings button.suggested-action { background: \(accent); color: #ffffff; }
        window.skrepka-settings button.skrepka-suggested:hover,
        window.skrepka-settings button.suggested-action:hover { background: alpha(\(accent), 0.88); }
        window.skrepka-settings dropdown > button { min-width: 150px; padding: 0 10px 0 14px; }
        window.skrepka-settings dropdown > button arrow { color: \(palette.secondary); }
        """
    }

    private static func switches(_ palette: SkrepkaPalette, accent: String) -> String {
        """
        window.skrepka-settings switch {
          background: \(palette.control); border: none; border-radius: 14px; box-shadow: none; outline: none;
          min-width: 46px; min-height: 28px; padding: 0; color: transparent;
        }
        window.skrepka-settings switch:checked { background: \(accent); }
        window.skrepka-settings switch:disabled { opacity: 0.45; }
        window.skrepka-settings switch:focus-visible { box-shadow: 0 0 0 2px alpha(\(accent), 0.7); }
        window.skrepka-settings switch > image { color: transparent; }
        window.skrepka-settings switch > slider {
          background: \(palette.knob); border: none; border-radius: 12px; outline: none;
          min-width: 24px; min-height: 24px; margin: 2px;
          box-shadow: 0 1px 3px rgba(0,0,0,0.30), 0 0 0 0.5px rgba(0,0,0,0.06);
        }
        """
    }

    /// The drop-downs' lists. A popover is its own surface, but its CSS node
    /// hangs off the drop-down, so the window's class still reaches it.
    static func popovers(_ palette: SkrepkaPalette, accent: String, isDark: Bool) -> String {
        let surface = isDark ? "rgb(44,44,46)" : "rgb(255,255,255)"
        return """
            window.skrepka-settings popover > contents {
              background: \(surface); color: \(palette.primary);
              border: 0.5px solid \(palette.border); border-radius: 10px; padding: 5px;
              box-shadow: 0 8px 24px \(palette.shadowNear);
            }
            window.skrepka-settings popover > arrow { background: \(surface); border: 0.5px solid \(palette.border); }
            window.skrepka-settings popover listview { background: none; }
            window.skrepka-settings popover listview > row {
              border-radius: 6px; padding: 6px 10px; min-height: 30px; color: \(palette.primary); background: none;
            }
            window.skrepka-settings popover listview > row:hover { background: \(palette.tile); }
            window.skrepka-settings popover listview > row:selected { background: \(accent); color: #ffffff; }
            window.skrepka-settings popover listview > row:selected image { color: #ffffff; }
            """
    }
}

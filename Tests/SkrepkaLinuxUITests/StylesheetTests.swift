import Foundation
import Testing

@testable import SkrepkaLinuxUI

/// Both stylesheets share one display, so each must style only its own
/// widgets — the picker's look must not change because Settings loaded, and
/// Settings must not restyle a widget outside its window.
@Suite("Stylesheets")
struct StylesheetTests {
    /// Every selector's first compound, from a stylesheet's rule headers.
    static func leadingSelectors(_ css: String) -> [String] {
        css.components(separatedBy: "}")
            .compactMap { $0.components(separatedBy: "{").first }
            .flatMap { $0.components(separatedBy: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { $0.components(separatedBy: " ").first }
    }

    @Test("every Settings rule is scoped to its window or a skrepka- class", arguments: [true, false])
    func settingsScoped(isDark: Bool) {
        let selectors = Self.leadingSelectors(SettingsStyle.css(isDark: isDark, accent: "rgb(1,2,3)"))
        #expect(!selectors.isEmpty)
        for selector in selectors {
            let scoped =
                selector.hasPrefix("window.skrepka-settings") || selector.hasPrefix(".skrepka-")
                || selector.hasPrefix("list.skrepka-")
            #expect(scoped, "unscoped selector: \(selector)")
        }
    }

    @Test("the Settings stylesheet carries the accent and the picker's palette")
    func settingsPalette() {
        let css = SettingsStyle.css(isDark: true, accent: "rgb(1,2,3)")
        #expect(css.contains("switch:checked { background: rgb(1,2,3); }"))
        #expect(css.contains(SkrepkaPalette.dark.hairline))
        #expect(!css.contains(SkrepkaPalette.light.window))
    }

    @Test("the picker keeps its window, panel and overlay rules and its inset")
    func pickerRules() {
        let css = PickerStyle.css(isDark: true, accent: "rgb(1,2,3)")
        #expect(css.contains("window.skrepka-picker { background: transparent; }"))
        #expect(css.contains("margin: \(PickerStyle.plainInset)px;"))
        #expect(css.contains("window.skrepka-overlay .skrepka-panel {\n  margin: 0;"))
        #expect(css.contains("background: \(SkrepkaPalette.dark.panel);"))
        #expect(PickerStyle.defaultAccent == SkrepkaPalette.defaultAccent)
    }

    @Test("the two stylesheets live in different slots")
    func slots() {
        #expect(CssInstaller.Slot.picker.rawValue != CssInstaller.Slot.settings.rawValue)
    }

    @Test("every section has a title and an icon chain, in the Mac's order")
    func sections() {
        #expect(
            SettingsSection.allCases.map(\.title) == ["General", "History", "Privacy", "Sync", "Status"])
        #expect(SettingsSection.allCases.allSatisfy { $0.iconNames.count == 3 })
        #expect(SettingsSection(named: "Sync") == .sync)
        #expect(SettingsSection(named: "status") == .diagnostics)
        #expect(SettingsSection(named: "diagnostics") == .diagnostics)
        #expect(SettingsSection(named: "nope") == nil)
    }
}

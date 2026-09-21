import Foundation
import SkrepkaLinuxUI

// A screenshot rig for the Settings window on a real compositor.
//
// It opens the real window against an in-process fake daemon, so every pane
// can be seen — and clicked through — without `skrepkad`. Environment
// variables pick what to draw, so one binary produces every screenshot:
//
//   SKREPKA_DEMO_SECTION    = general | history | privacy | sync | status
//                             (default general)
//   SKREPKA_DEMO_APPEARANCE = dark | light                   (default dark)
//   SKREPKA_DEMO_DAEMON     = current | old                  (default current;
//                             old claims interface version 3, which cannot
//                             change settings)
//   SKREPKA_DEMO_PROBLEMS   = 1 to have Diagnostics report a problem
//
// It is not a product. `skrepka-gui` is the Settings window for the real
// installation.

let environment = ProcessInfo.processInfo.environment
let appearance =
    environment["SKREPKA_DEMO_APPEARANCE"] == "light"
    ? AppearancePreference(colorScheme: .light, accent: nil)
    : AppearancePreference(colorScheme: .dark, accent: nil)
let section = environment["SKREPKA_DEMO_SECTION"].flatMap(SettingsSection.init(named:)) ?? .general
let daemon = FakeSettingsDaemon(
    version: environment["SKREPKA_DEMO_DAEMON"] == "old" ? 3 : 4,
    withProblems: environment["SKREPKA_DEMO_PROBLEMS"] == "1"
)
let autostart = FileManager.default.temporaryDirectory
    .appendingPathComponent("skrepka-settings-demo-autostart.desktop")

let options = SettingsDemo.Options(
    section: section,
    appearance: appearance,
    shortcut: .bound("Meta+Shift+V"),
    autostartFile: autostart
)
exit(SettingsDemo.run(options: options) { daemon })

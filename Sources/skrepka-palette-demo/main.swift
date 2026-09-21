import CGtk4
import Foundation
import SkrepkaCore
import SkrepkaLinuxUI

// A hand-driven smoke test and screenshot rig for the picker on a real
// compositor.
//
// It drives the real `PickerController` against an in-process fake daemon with
// canned rows, so the whole picker — search, rows, thumbnails, footer, empty
// states — can be seen on the Steam Deck without `skrepkad`. Two environment
// variables pick what to draw, so one binary produces every screenshot:
//
//   SKREPKA_DEMO_APPEARANCE = dark | light   (default dark)
//   SKREPKA_DEMO_STATE      = list | empty    (default list)
//
// It is not a product — no tray, no hotkey, no daemon. `skrepka-gui` is the
// picker for the real installation.

guard GtkSession.start() else {
    FileHandle.standardError.write(Data("skrepka-palette-demo: could not open display\n".utf8))
    exit(2)
}

let environment = ProcessInfo.processInfo.environment
let appearance =
    environment["SKREPKA_DEMO_APPEARANCE"] == "light"
    ? AppearancePreference(colorScheme: .light, accent: nil)
    : AppearancePreference(colorScheme: .dark, accent: nil)
let showEmpty = environment["SKREPKA_DEMO_STATE"] == "empty"

let daemon = FakePickerDaemon(
    rows: showEmpty ? [] : DemoClips.all(),
    previewPNG: DemoClips.previewPNG())

do {
    let controller = try PickerController(connect: { daemon })
    controller.onOpenSettings = {
        FileHandle.standardOutput.write(Data("open settings\n".utf8))
    }
    controller.apply(appearance)
    controller.start()
    controller.show()
    // SKREPKA_DEMO_MENU=1 pops the row context menu open a moment after the
    // surface maps, so a screenshot can prove it renders on the layer-shell
    // surface — right-clicks cannot be synthesised under the headless harness.
    if environment["SKREPKA_DEMO_MENU"] == "1" {
        controller.openMenuForSelection(afterSeconds: 1)
    }
    GtkSession.run()
} catch {
    FileHandle.standardError.write(Data("skrepka-palette-demo: \(error)\n".utf8))
    exit(3)
}

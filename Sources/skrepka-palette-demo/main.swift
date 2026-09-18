import Foundation
import SkrepkaCore
import SkrepkaLinuxUI

// A hand-driven smoke test for `PaletteWindow` on a real compositor.
//
// The prototype under `prototypes/palette-bakeoff/` proved the picker maps and
// takes keys on a headless sway. Phase 7 step 1 asks the same of KWin, and no
// headless run can answer that — the compositor has to be the one under the
// user's session. This binary is the smallest thing that opens the palette on
// whatever session is running, with canned rows and no history store, and
// prints every key command and query change to stdout so a checklist can tick.
//
// It is not a product — no menu-bar entry, no daemon, no hotkey. `skrepkad`
// remains the picker for the real installation. `skrepka-palette-demo` is only
// what you launch by hand on the Steam Deck to answer "does the palette come
// up over KWin".

guard GtkSession.start() else {
    FileHandle.standardError.write(Data("skrepka-palette-demo: could not open display\n".utf8))
    exit(2)
}

FileHandle.standardOutput.write(Data("layer-shell available: \(GtkSession.isLayerShellAvailable)\n".utf8))
FileHandle.standardOutput.write(Data("layer-shell protocol: \(GtkSession.layerShellProtocolVersion)\n".utf8))

let rows: [ClipSummary] = (1...8).map { index in
    ClipSummary(
        id: UUID(),
        kind: .text,
        text: "Sample clip \(index) — pretend clipboard history for the Deck bring-up.",
        sourceBundleID: nil,
        createdAt: Date(),
        isPinned: false,
        isConcealed: false,
        imageSize: nil,
        byteCount: nil,
        fileCount: 0,
        hasThumbnail: false
    )
}

do {
    let window = try PaletteWindow()
    window.onQueryChanged = { query in
        FileHandle.standardOutput.write(Data("query: \(query)\n".utf8))
    }
    window.onCommand = { command in
        FileHandle.standardOutput.write(Data("command: \(command)\n".utf8))
        switch command {
        case .dismiss, .choose, .chooseRow:
            GtkSession.stop()
        default:
            break
        }
    }
    window.show(rows)
    window.present()
    GtkSession.run()
} catch {
    FileHandle.standardError.write(Data("skrepka-palette-demo: \(error)\n".utf8))
    exit(3)
}

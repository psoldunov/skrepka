import CGtk
import Foundation

// Phase 7 bake-off, prototype C: the floating palette expressed in raw GTK4
// through C interop, with no third-party Swift GUI framework.
//
// What it has to demonstrate, per docs/linux-sync/phase-7-linux-gui.md step 1:
//
//   1. a window that takes keyboard input without the app underneath losing
//      what it was doing
//   2. placement centred on the active output, not on output zero
//   3. Escape dismisses, arrows navigate, Return selects, and the first
//      keystroke after the hotkey lands in the search field
//   4. it works on Sway *and* on KDE
//
// `--victim` runs the other half of the test: a plain toplevel with a text
// entry, so there is something underneath to lose focus and get it back.
//
// Not named main.swift on purpose — a file with that name is top-level code,
// and `@main` is refused in a module that contains any.
//
// Every GObject type arrives from the module map as `OpaquePointer`: GTK's
// structs are opaque in the public headers, so Clang has no layout to import
// and Swift has no `GtkWindow` type to point at. That is the single biggest
// ergonomic cost of the raw-interop route — the compiler cannot tell a
// GtkWindow from a GtkEntry — and it is what a generated binding buys you.

/// One line on stdout, flushed, so the headless harness reads events as they
/// happen rather than in one block when the process exits. `print` cannot be
/// used: stdout is block-buffered when piped, and the C `stdout` global is a
/// `var` that Swift 6 refuses to touch from concurrency-checked code.
private func emit(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

/// X11 keysyms, from `/usr/include/gtk-4.0/gdk/gdkkeysyms.h` lines 43, 47, 76,
/// 78. Spelled out rather than imported because the `GDK_KEY_*` names are
/// object-like macros, and a build that silently stopped importing them would
/// fall back to matching nothing — which reads as "the compositor ate the key"
/// rather than as a build problem.
private enum Key {
    static let escape: UInt32 = 0xff1b
    static let up: UInt32 = 0xff52
    static let down: UInt32 = 0xff54
    static let enter: UInt32 = 0xff0d
    static let one: UInt32 = 0x0031
    static let nine: UInt32 = 0x0039
    /// `GDK_ALT_MASK = 1 << 3`, gdkenums.h:129.
    static let altMask: UInt32 = 1 << 3
}

/// Everything the C callbacks need, reached through the `gpointer` user-data
/// argument every GTK signal carries.
///
/// Deliberately not `Sendable` and deliberately not `@MainActor`. A
/// `@convention(c)` function is `nonisolated`, it reconstructs this from an
/// opaque pointer, and nothing crosses an isolation boundary — so the compiler
/// raises nothing, which is worth being honest about: the `void *` is a hole in
/// concurrency checking rather than a proof of safety. It is still preferable
/// to `@unchecked Sendable` or `MainActor.assumeIsolated`, both of which this
/// repository bans, because it makes no claim at all instead of a false one.
private final class Palette {
    // Three different pointer flavours for three GObject types, and the
    // difference is not a choice: GTK's headers define `struct _GtkWindow` and
    // `struct _GtkWidget` publicly, so Clang imports those as real Swift
    // structs, while `GtkListBox` is only forward-declared and arrives as an
    // `OpaquePointer`. Raw interop inherits whichever spelling each header
    // happens to use.
    let window: UnsafeMutablePointer<GtkWindow>
    let list: OpaquePointer
    let search: UnsafeMutablePointer<GtkWidget>
    let rows: [String]
    var visible: [String]

    init(
        window: UnsafeMutablePointer<GtkWindow>,
        list: OpaquePointer,
        search: UnsafeMutablePointer<GtkWidget>,
        rows: [String]
    ) {
        self.window = window
        self.list = list
        self.search = search
        self.rows = rows
        self.visible = rows
    }

    func selectedIndex() -> Int {
        guard let row = gtk_list_box_get_selected_row(list) else { return -1 }
        return Int(gtk_list_box_row_get_index(row))
    }

    func select(_ index: Int) {
        guard !visible.isEmpty else { return }
        let clamped = max(0, min(index, visible.count - 1))
        guard let row = gtk_list_box_get_row_at_index(list, Int32(clamped)) else { return }
        gtk_list_box_select_row(list, row)
    }

    /// Reports the selection the way the headless harness reads it: one line on
    /// stdout, so a test asserts on text rather than on pixels.
    func commit() {
        let index = selectedIndex()
        guard index >= 0, index < visible.count else {
            emit("SELECTED none")
            return
        }
        emit("SELECTED \(visible[index])")
    }

    func refilter(_ needle: String) {
        visible =
            needle.isEmpty
            ? rows : rows.filter { $0.lowercased().contains(needle.lowercased()) }
        while let row = gtk_list_box_get_row_at_index(list, 0) {
            gtk_list_box_remove(list, skrepka_row_as_widget(row))
        }
        for text in visible {
            gtk_list_box_append(list, gtk_label_new(text))
        }
        select(0)
        emit("FILTER \(needle.isEmpty ? "<empty>" : needle) -> \(visible.count)")
    }
}

// MARK: - Callbacks

private func palette(from data: gpointer?) -> Palette? {
    guard let data else { return nil }
    return Unmanaged<Palette>.fromOpaque(data).takeUnretainedValue()
}

private let onKey:
    @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean = {
        _, keyval, _, state, data in
        guard let palette = palette(from: data) else { return 0 }

        switch keyval {
        case Key.escape:
            emit("KEY escape")
            gtk_window_close(palette.window)
            return 1
        case Key.up:
            palette.select(palette.selectedIndex() - 1)
            emit("KEY up -> \(palette.selectedIndex())")
            return 1
        case Key.down:
            palette.select(palette.selectedIndex() + 1)
            emit("KEY down -> \(palette.selectedIndex())")
            return 1
        case Key.enter:
            palette.commit()
            gtk_window_close(palette.window)
            return 1
        case Key.one...Key.nine where state & Key.altMask != 0:
            // The ⌘1–⌘9 equivalent. Alt rather than Ctrl: Ctrl+1..9 is tab
            // switching in every browser and terminal on the platform.
            palette.select(Int(keyval - Key.one))
            palette.commit()
            gtk_window_close(palette.window)
            return 1
        default:
            // Everything else falls through to the search entry, which is what
            // makes the first keystroke after the hotkey land in the field.
            return 0
        }
    }

private let onSearchChanged: @convention(c) (OpaquePointer?, gpointer?) -> Void = {
    editable, data in
    guard let palette = palette(from: data), let editable else { return }
    let text = gtk_editable_get_text(editable)
    palette.refilter(text.map(String.init(cString:)) ?? "")
}

private let onDestroy: @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, _ in
    emit("CLOSED")
    exit(0)
}

// MARK: - Entry point

@main
enum Main {
    static func main() {
        let victim = CommandLine.arguments.contains("--victim")
        gtk_init()

        let major = gtk_layer_get_major_version()
        let minor = gtk_layer_get_minor_version()
        let micro = gtk_layer_get_micro_version()
        emit("LAYER_SHELL_SUPPORTED \(gtk_layer_is_supported() != 0)")
        emit("LAYER_SHELL_VERSION \(major).\(minor).\(micro)")
        emit("LAYER_SHELL_PROTOCOL_VERSION \(gtk_layer_get_protocol_version())")

        if victim {
            runVictim()
        } else {
            // `exclusive` or `on_demand`, chosen at the command line because the
            // difference is the whole question and a prototype that hard-codes
            // one answers half of it.
            let exclusive = !CommandLine.arguments.contains("--on-demand")
            runPalette(exclusive: exclusive)
        }

        let loop = g_main_loop_new(nil, 0)
        g_main_loop_run(loop)
    }

    /// The app underneath: an ordinary toplevel with a text field, so the
    /// harness has something whose focus and caret can be checked before and
    /// after the palette appears.
    static func runVictim() {
        // Every one of these arrives Optional: a `static inline` returning a
        // plain C pointer imports as `T?`, not as an implicitly-unwrapped
        // pointer, so the raw route makes you say what happens when GTK hands
        // back null. Which is fair — but it is one guard per widget.
        guard let window = skrepka_as_window(gtk_window_new()), let entry = gtk_entry_new(),
            let editable = skrepka_as_editable(entry)
        else {
            emit("VICTIM_FAILED")
            return
        }
        gtk_window_set_title(window, "victim")
        gtk_window_set_default_size(window, 600, 400)
        gtk_editable_set_text(editable, "caret lives here")
        gtk_window_set_child(window, entry)
        gtk_window_present(window)
        emit("VICTIM_PRESENTED")
    }

    static func runPalette(exclusive: Bool) {
        guard let window = skrepka_as_window(gtk_window_new()),
            let column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8),
            let box = skrepka_as_box(column),
            let search = gtk_entry_new(),
            let listWidget = gtk_list_box_new(),
            let list = skrepka_as_list_box(listWidget),
            let keys = gtk_event_controller_key_new(),
            let windowWidget = skrepka_window_as_widget(window)
        else {
            emit("PALETTE_FAILED")
            return
        }
        gtk_window_set_decorated(window, 0)
        gtk_window_set_default_size(window, 640, 420)

        // The whole overlay story, and the only part of it that is not ordinary
        // GTK. No anchors at all is what centres the surface: the layer-shell
        // spec leaves an unanchored surface to the compositor, and both sway
        // and KWin centre it on the output the surface was assigned to.
        gtk_layer_init_for_window(window)
        gtk_layer_set_layer(window, GTK_LAYER_SHELL_LAYER_OVERLAY)
        gtk_layer_set_namespace(window, "skrepka-picker")
        // `on_demand` reads better on paper — "focusable, but not stealing" —
        // and does not do what a picker needs: the spec leaves it
        // implementation-defined and sway only hands focus over on a click, so
        // the keystroke after the hotkey goes to the app underneath. `exclusive`
        // is what actually delivers keys the moment the surface maps.
        gtk_layer_set_keyboard_mode(
            window,
            exclusive
                ? GTK_LAYER_SHELL_KEYBOARD_MODE_EXCLUSIVE
                : GTK_LAYER_SHELL_KEYBOARD_MODE_ON_DEMAND)
        emit("KEYBOARD_MODE \(exclusive ? "exclusive" : "on_demand")")

        gtk_box_append(box, search)
        gtk_box_append(box, listWidget)
        gtk_window_set_child(window, column)

        let palette = Palette(
            window: window,
            list: list,
            search: search,
            rows: ["alpha clip", "bravo clip", "charlie clip", "delta clip"]
        )
        palette.refilter("")

        // Retained for the process's lifetime on purpose: the C side holds this
        // pointer for as long as the window exists, and a prototype that let it
        // go would crash in a way that says nothing about the toolkit.
        let context = Unmanaged.passRetained(palette).toOpaque()

        // Capture, not bubble. In the bubble phase the focused GtkEntry sees
        // every key first and swallows the ones a picker needs — Down and
        // Return never reach the window at all, which was the first thing the
        // headless harness caught. Capture runs the window's controller before
        // the focus widget, so navigation keys are handled here and everything
        // else falls through to the search field untouched.
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        skrepka_connect(
            UnsafeMutableRawPointer(keys), "key-pressed",
            unsafeBitCast(onKey, to: GCallback.self), context)
        gtk_widget_add_controller(windowWidget, keys)
        skrepka_connect(
            UnsafeMutableRawPointer(search), "changed",
            unsafeBitCast(onSearchChanged, to: GCallback.self), context)
        skrepka_connect(
            UnsafeMutableRawPointer(window), "destroy",
            unsafeBitCast(onDestroy, to: GCallback.self), context)

        gtk_window_present(window)
        _ = gtk_widget_grab_focus(search)
        emit("PALETTE_PRESENTED")
    }
}

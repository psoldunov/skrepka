import CGtk4
import SkrepkaCore

/// The picker's floating palette: an undecorated, centred, keyboard-driven
/// overlay that appears over the frontmost app.
///
/// The macOS counterpart is an `NSPanel` with `.nonactivatingPanel`, which lets
/// the app underneath stay active. Wayland has no such thing — a plain
/// `xdg_toplevel` cannot decline activation, and `xdg-activation-v1` only hands
/// out tokens to raise *other* surfaces. The mechanism that does exist is
/// `zwlr_layer_shell_v1`, reached here through `gtk4-layer-shell`, and it is
/// implemented by both compositors this port targets: KWin registers it
/// unconditionally for unsandboxed clients, and sway gates it on the same
/// security-context check.
///
/// The behaviour that results is close to the Mac's but not identical, and the
/// difference is worth stating rather than papering over: the app underneath
/// loses *keyboard focus* while the palette is up, and gets it back the moment
/// the palette closes. It keeps its selection and its caret, which is what the
/// paste depends on. Verified under a headless sway — see
/// `prototypes/palette-bakeoff/`.
///
/// `nonisolated`, and reached from the C callbacks through the `gpointer`
/// user-data argument every GTK signal carries. That pointer is a hole in
/// concurrency checking rather than a proof of safety, and saying so is the
/// point: the alternatives are `@unchecked Sendable` and
/// `MainActor.assumeIsolated`, both of which this repository bans because each
/// is a claim about something the compiler cannot see. Making no claim is
/// honest; making a false one is not. Every method here runs on GTK's main
/// loop thread and nothing else may touch an instance.
public final class PaletteWindow {
    /// Why the palette could not be built.
    public enum Unavailable: Error, CustomStringConvertible {
        /// The compositor advertises no `zwlr_layer_shell_v1`.
        ///
        /// GNOME and every X11 session land here. It is not a degraded mode to
        /// work around — without it there is no way to show a keyboard-driven
        /// surface over the frontmost app at all.
        case layerShellMissing
        /// GTK refused to build a widget. Practically unreachable, and not
        /// worth a force-unwrap to pretend otherwise.
        case widgetCreationFailed

        public var description: String {
            switch self {
            case .layerShellMissing:
                """
                This desktop does not offer the wlr-layer-shell protocol, which is what \
                lets the picker appear over the app you are using. Skrepka's history is \
                still available from the skrepka command.
                """
            case .widgetCreationFailed:
                "The picker could not be built."
            }
        }
    }

    /// Rows to move for Page Up and Page Down.
    ///
    /// The same jump the macOS picker uses, so the two lists scroll by the same
    /// amount rather than by whatever each platform's list widget thinks a page
    /// is.
    public static let pageJump = 5

    /// Sends a decoded key press out. The window itself decides nothing.
    public var onCommand: ((PickerCommand) -> Void)?
    /// Fires as the search field changes, with what is now in it.
    public var onQueryChanged: ((String) -> Void)?

    private let window: UnsafeMutablePointer<GtkWindow>
    /// The same object as ``window``, pre-cast. Kept rather than re-derived
    /// because ``close()`` needs it on a path where throwing is not an option.
    private let windowWidget: UnsafeMutablePointer<GtkWidget>
    private let list: OpaquePointer
    private let searchWidget: UnsafeMutablePointer<GtkWidget>
    /// GTK's public headers forward-declare GtkEditable, so Swift imports its
    /// validated pointer as OpaquePointer rather than a named type.
    private let search: OpaquePointer
    /// The rows the list is actually showing, which is what ``selection`` reads
    /// by index — see ``show(_:)``.
    private var rows: [ClipSummary] = []

    /// A conservative height for the output the palette will land on, read once.
    /// GDK reports 0 before the display is open, which ``PaletteMetrics`` reads
    /// as "unknown" and answers with the fixed maximum.
    private let outputHeight = skrepka_smallest_monitor_height()

    /// - Throws: ``Unavailable`` when the session cannot show a palette.
    public init() throws {
        guard GtkSession.isLayerShellAvailable else { throw Unavailable.layerShellMissing }

        // Every one of these arrives Optional: a C function returning a plain
        // pointer imports as `T?`, so the raw-interop route makes you say what
        // happens when GTK hands back null. One guard covers the lot.
        guard let window = skrepka_as_window(gtk_window_new()),
            let column = gtk_box_new(GTK_ORIENTATION_VERTICAL, PaletteMetrics.gutter),
            let box = skrepka_as_box(column),
            let searchWidget = gtk_entry_new(),
            let search = skrepka_as_editable(searchWidget),
            let listWidget = gtk_list_box_new(),
            let list = skrepka_as_list_box(listWidget),
            let scroller = gtk_scrolled_window_new(),
            let scrollBox = skrepka_as_scrolled_window(scroller),
            let keys = gtk_event_controller_key_new(),
            let windowWidget = skrepka_window_as_widget(window)
        else { throw Unavailable.widgetCreationFailed }

        self.window = window
        self.windowWidget = windowWidget
        self.list = list
        self.searchWidget = searchWidget
        self.search = search

        gtk_window_set_decorated(window, 0)
        gtk_window_set_default_size(
            window,
            PaletteMetrics.width,
            PaletteMetrics.height(rows: [], outputHeight: outputHeight)
        )
        Self.raiseAsOverlay(window)

        gtk_scrolled_window_set_child(scrollBox, listWidget)
        gtk_widget_set_vexpand(scroller, 1)
        gtk_box_append(box, searchWidget)
        gtk_box_append(box, scroller)
        gtk_window_set_child(window, column)

        connectSignals(keys: keys)
    }

    /// Wires the two signals the palette listens to.
    ///
    /// Split out of ``init()`` rather than inlined, and not only for length:
    /// this is the one place the instance is handed to C, so it is worth being
    /// the one place to look when asking who owns the window.
    ///
    /// One `passRetained` **per connection**, each balanced by its own
    /// `GClosureNotify`. Not one retain shared by both, which is the shape that
    /// reads as economical and is wrong: GLib calls the notify once per closure
    /// it destroys, so a single +1 against two notifies over-releases the
    /// moment the second one fires. Two of each is the arithmetic that holds
    /// however GTK chooses to tear the widgets down, and in whatever order.
    ///
    /// Nothing here releases by hand, which is the point. GTK owns the widgets
    /// and decides when they die; a caller that released on its own schedule
    /// would either do it while a handler was still connected — leaving C
    /// holding freed memory — or never do it at all.
    private func connectSignals(keys: OpaquePointer) {
        // Capture, not bubble. In the bubble phase the focused GtkEntry sees
        // every key first and swallows the ones the picker needs — Down and
        // Return never reach the window at all, which is the first thing the
        // headless harness caught. Capture runs this controller before the
        // focus widget, and `.type` hands everything else back to the entry.
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        skrepka_connect(
            UnsafeMutableRawPointer(keys),
            "key-pressed",
            unsafeBitCast(Self.onKeyPressed, to: GCallback.self),
            Unmanaged.passRetained(self).toOpaque(),
            Self.onContextReleased
        )
        gtk_widget_add_controller(windowWidget, keys)
        skrepka_connect(
            UnsafeMutableRawPointer(search),
            "changed",
            unsafeBitCast(Self.onSearchChanged, to: GCallback.self),
            Unmanaged.passRetained(self).toOpaque(),
            Self.onContextReleased
        )
    }

    // MARK: - Presenting

    /// Shows the palette with a fresh query and top selection, then puts the
    /// caret in the search field. This matches ``PickerModel/reset`` on macOS:
    /// every hotkey opening starts from the complete, first-selected history.
    public func present() {
        gtk_editable_set_text(search, "")
        select(0)
        gtk_window_present(window)
        // After `present`, not before: the entry has to be realised for focus
        // to stick, which is the same ordering problem the macOS panel has with
        // its `focusToken`.
        _ = gtk_widget_grab_focus(searchWidget)
    }

    /// Takes the palette off screen, keeping it ready to open again.
    ///
    /// Hide, not destroy, and the reason is what a picker *is*: the hotkey
    /// opens it dozens of times a session, so tearing the widget tree down on
    /// every dismissal would rebuild the window, the list and the entry each
    /// time — and each rebuild is a frame the user waits for after pressing the
    /// hotkey, on the one interaction that has to feel instant.
    ///
    /// It is also what makes this method safe to call at all. `gtk_window_close`
    /// destroys the window: GTK's toplevel list holds the only reference, so
    /// removing it finalizes the window and its children on the spot and leaves
    /// ``window``, ``list`` and ``search`` dangling — every later `present()` a
    /// use-after-free. And it returns early on an unrealized window, so closing
    /// before the first `present()` would tear down nothing while still running
    /// whatever cleanup was paired with it. Hiding has neither problem and is
    /// idempotent: any number of calls, in any order, before or after
    /// ``present()``.
    public func close() {
        gtk_widget_set_visible(windowWidget, 0)
    }

    // MARK: - Contents

    /// Replaces the rows, keeping the selection at the top.
    ///
    /// Takes `ClipSummary` straight from `SkrepkaCore` — the same value the
    /// macOS list renders — so the two platforms cannot disagree about what a
    /// row says.
    public func show(_ rows: [ClipSummary]) {
        gtk_list_box_remove_all(list)

        // `break`, not `continue`, and ``rows`` set from what landed rather
        // than from what was asked for. ``selection`` looks up the index GTK
        // reports against this array, so the two have to describe the same
        // list: skipping past a failed label would shift every row after it by
        // one and make the picker paste a clip the user never saw. Taking the
        // prefix that built cannot misalign — it can only show fewer rows.
        var shown: [ClipSummary] = []
        for row in rows {
            guard let label = gtk_label_new(row.previewText) else { break }
            gtk_label_set_xalign(skrepka_as_label(label), 0)
            gtk_label_set_ellipsize(skrepka_as_label(label), PANGO_ELLIPSIZE_END)
            gtk_list_box_append(list, label)
            shown.append(row)
        }
        self.rows = shown

        gtk_window_set_default_size(
            window,
            PaletteMetrics.width,
            PaletteMetrics.height(rows: shown, outputHeight: outputHeight)
        )
        select(0)
    }

    /// The row the user is on, or nil when the list is empty.
    public var selection: ClipSummary? {
        let index = selectedIndex
        guard rows.indices.contains(index) else { return nil }
        return rows[index]
    }

    public var selectedIndex: Int {
        guard let row = gtk_list_box_get_selected_row(list) else { return -1 }
        return Int(gtk_list_box_row_get_index(row))
    }

    /// Moves the selection, clamped to the list.
    public func moveSelection(by offset: Int) {
        select(selectedIndex + offset)
    }

    public func select(_ index: Int) {
        guard !rows.isEmpty else { return }
        let clamped = min(max(index, 0), rows.count - 1)
        guard let row = gtk_list_box_get_row_at_index(list, Int32(clamped)) else { return }
        gtk_list_box_select_row(list, row)
    }

    public var query: String {
        guard let text = gtk_editable_get_text(search) else { return "" }
        return String(cString: text)
    }

    // MARK: - Layer shell

    /// Everything that makes this a palette rather than a window.
    ///
    /// No anchors at all is what centres it: the layer-shell spec leaves an
    /// unanchored surface's position to the compositor, and both sway and KWin
    /// centre it on the output the surface was assigned to — which is the
    /// active output, not output zero, because that is where the compositor put
    /// the surface.
    ///
    /// `exclusive` rather than `on_demand`, and that is the one place the
    /// obvious-sounding option is wrong. `on_demand` reads as "focusable but
    /// not stealing", and the protocol leaves it implementation-defined: sway
    /// only hands focus over on a click, so the keystroke after the hotkey goes
    /// to the app underneath and the search field stays empty. `exclusive`
    /// delivers keys the moment the surface maps, which is what a picker opened
    /// by a hotkey needs.
    private static func raiseAsOverlay(_ window: UnsafeMutablePointer<GtkWindow>) {
        gtk_layer_init_for_window(window)
        gtk_layer_set_layer(window, GTK_LAYER_SHELL_LAYER_OVERLAY)
        gtk_layer_set_namespace(window, "skrepka-picker")
        gtk_layer_set_keyboard_mode(window, GTK_LAYER_SHELL_KEYBOARD_MODE_EXCLUSIVE)
    }
}

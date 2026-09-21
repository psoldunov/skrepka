import CGtk4
import SkrepkaCore
import SkrepkaIPC

/// The picker's floating window: an undecorated, keyboard-driven surface that
/// appears over the frontmost app, hosting the one ``PickerPanel``.
///
/// There are two ways to raise it, chosen by what the session offers. Where the
/// compositor speaks `zwlr_layer_shell_v1` — KWin and sway — it is a centred
/// overlay layer surface with exclusive keyboard focus, which is the only
/// Wayland mechanism that puts a keyboard-driven surface over the frontmost app
/// without stealing its selection. Where it does not — every X11 session, and
/// GNOME — it falls back to an ordinary undecorated toplevel; on X11 that
/// toplevel is marked above/skip-taskbar and grabs the keyboard on map, the way
/// rofi does, so the first keystroke after the hotkey still lands in the search
/// field. It no longer refuses to build for want of layer-shell.
///
/// `nonisolated`, and reached from the C key callback through the `gpointer`
/// user data every GTK signal carries — the honest hole in concurrency checking
/// this target describes rather than papers over. Every method runs on GTK's
/// loop thread and nothing else may touch an instance.
public final class PaletteWindow {
    /// Why the palette could not be built. Layer-shell's absence is no longer
    /// one of them — see the type's discussion.
    public enum Unavailable: Error, CustomStringConvertible {
        case widgetCreationFailed

        public var description: String {
            switch self {
            case .widgetCreationFailed: "The picker could not be built."
            }
        }
    }

    /// Rows Page Up and Page Down move, matching the macOS picker.
    public static let pageJump = 5
    /// The transparent border the window keeps around the panel so the panel's
    /// drop shadow has room to fall — the same value as the panel's CSS margin.
    private static let shadowInset: Int32 = 22
    /// The empty state's height, matching `PaletteMetrics`.
    private static let emptyHeight: Int32 = 150

    /// Sends a decoded key press out; the window decides nothing.
    public var onCommand: ((PickerCommand) -> Void)?

    /// The panel the window hosts, for the controller to drive.
    let panel: PickerPanel

    private let window: UnsafeMutablePointer<GtkWindow>
    private let windowWidget: UnsafeMutablePointer<GtkWidget>
    private let usesLayerShell: Bool
    private let outputHeight = skrepka_smallest_monitor_height()
    /// The last size set, so an unchanged resize is skipped — repeatedly setting
    /// the same default size re-commits the layer surface and can cost a key.
    private var lastSize: (Int32, Int32)?

    public init() throws {
        guard let panel = PickerPanel(),
            let window = skrepka_as_window(gtk_window_new()),
            let windowWidget = skrepka_window_as_widget(window),
            let keys = gtk_event_controller_key_new()
        else { throw Unavailable.widgetCreationFailed }

        self.panel = panel
        self.window = window
        self.windowWidget = windowWidget
        usesLayerShell = GtkSession.isLayerShellAvailable

        gtk_window_set_decorated(window, 0)
        gtk_widget_add_css_class(windowWidget, "skrepka-picker")
        gtk_window_set_child(window, panel.root)
        if usesLayerShell {
            Self.raiseAsOverlay(window)
        } else {
            wirePlainWindow()
        }
        connectKeys(keys)
        resize(for: [])
    }

    // MARK: - Presenting

    public func present() {
        gtk_window_present(window)
        panel.list.scrollToTop()
        panel.searchBar.focus()
    }

    /// Hides the window, keeping it ready to open again — never destroys it, for
    /// the reasons the picker is opened dozens of times a session.
    public func close() {
        gtk_widget_set_visible(windowWidget, 0)
    }

    public var isVisible: Bool {
        gtk_widget_get_visible(windowWidget) != 0
    }

    /// Resizes the window to fit `documents`, clamped to the output, with room
    /// for the shadow. The arithmetic is `PaletteMetrics`', over the document's
    /// own "has a preview" flag rather than a `ClipSummary`'s.
    public func resize(for documents: [ClipDocument]) {
        let content = documents.reduce(Int32(0)) { $0 + Self.rowHeight(documents.isEmpty ? nil : $1) }
        let gutter = PaletteMetrics.gutter * Int32(max(0, documents.count - 1))
        let wanted =
            documents.isEmpty
            ? PaletteMetrics.chromeHeight + Self.emptyHeight
            : PaletteMetrics.chromeHeight + content + gutter
        let height = min(
            max(wanted, PaletteMetrics.minimumHeight),
            PaletteMetrics.ceiling(outputHeight: outputHeight))
        let width = PaletteMetrics.width + Self.shadowInset * 2
        let full = height + Self.shadowInset * 2
        if let lastSize, lastSize == (width, full) { return }
        lastSize = (width, full)
        gtk_window_set_default_size(window, width, full)
    }

    private static func rowHeight(_ document: ClipDocument?) -> Int32 {
        guard let document, document.hasPreview, !document.isConcealed else {
            return PaletteMetrics.standardRowHeight
        }
        return PaletteMetrics.imageRowHeight
    }

    // MARK: - Keys

    private func connectKeys(_ keys: OpaquePointer) {
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        skrepka_connect(
            UnsafeMutableRawPointer(keys),
            "key-pressed",
            unsafeBitCast(Self.onKeyPressed, to: GCallback.self),
            Unmanaged.passRetained(self).toOpaque(),
            Self.onContextReleased)
        gtk_widget_add_controller(windowWidget, keys)
    }

    // MARK: - Layer shell

    /// The overlay path: no anchors centres it, exclusive keyboard delivers the
    /// first keystroke without a click. See the prototype's findings.
    private static func raiseAsOverlay(_ window: UnsafeMutablePointer<GtkWindow>) {
        gtk_layer_init_for_window(window)
        gtk_layer_set_layer(window, GTK_LAYER_SHELL_LAYER_OVERLAY)
        gtk_layer_set_namespace(window, "skrepka-picker")
        gtk_layer_set_keyboard_mode(window, GTK_LAYER_SHELL_KEYBOARD_MODE_EXCLUSIVE)
    }

    // MARK: - X11 fallback

    /// Wires the plain toplevel's realize/map/unmap so an X11 session gets the
    /// utility hints and the keyboard grab a layer surface would have given it.
    /// On a non-X11 session without layer-shell — GNOME Wayland — these are
    /// no-ops and the window is a best-effort plain toplevel.
    private func wirePlainWindow() {
        GtkSignal.connect(UnsafeMutableRawPointer(windowWidget), "realize") { [weak self] in
            guard let surface = self?.surface() else { return }
            skrepka_x11_mark_utility(surface)
        }
        GtkSignal.connect(UnsafeMutableRawPointer(windowWidget), "map") { [weak self] in
            self?.presentX11()
        }
        GtkSignal.connect(UnsafeMutableRawPointer(windowWidget), "unmap") { [weak self] in
            guard let surface = self?.surface() else { return }
            skrepka_x11_ungrab_keyboard(surface)
        }
    }

    private func presentX11() {
        guard let surface = surface() else { return }
        skrepka_x11_center(surface, gtk_widget_get_width(windowWidget), gtk_widget_get_height(windowWidget))
        skrepka_x11_grab_keyboard(surface)
    }

    private func surface() -> OpaquePointer? {
        guard let native = skrepka_window_as_native(window) else { return nil }
        return gtk_native_get_surface(native)
    }
}

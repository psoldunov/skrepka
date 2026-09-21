import CGtk4
import SkrepkaCore
import SkrepkaIPC

/// The picker's floating window: an undecorated, keyboard-driven surface that
/// appears over the frontmost app, hosting the one ``PickerPanel``.
///
/// There are two ways to raise it, chosen by what the session offers. Where the
/// compositor speaks `zwlr_layer_shell_v1` — KWin and sway — it is an overlay
/// layer surface with exclusive keyboard focus, which is the only Wayland
/// mechanism that puts a keyboard-driven surface over the frontmost app without
/// stealing its selection. That surface covers the whole output and is
/// transparent outside the panel — see `PaletteWindow+Overlay.swift` for why.
/// Where there is no layer-shell — every X11 session, and GNOME — it falls back
/// to an ordinary undecorated toplevel the size of the panel; on X11 that
/// toplevel is marked above/skip-taskbar and grabs the keyboard on map, the way
/// rofi does, so the first keystroke after the hotkey still lands in the search
/// field. See `PaletteWindow+Plain.swift`.
///
/// Either way it closes when it stops being what the user is working with, as
/// the macOS panel closes when it resigns key: when keyboard focus moves to
/// another window, and — on the overlay, where a click elsewhere lands on the
/// overlay itself — when a click falls outside the panel. KWin moves focus off
/// even an exclusive layer surface when another window is clicked (it treats
/// exclusive and on-demand alike), and GDK turns that `wl_keyboard.leave` into
/// the window going inactive; sway keeps focus there, and the click does the
/// work instead.
///
/// `nonisolated`, and reached from the C key callback through the `gpointer`
/// user data every GTK signal carries — the honest hole in concurrency checking
/// this target describes rather than papers over. Every method runs on GTK's
/// loop thread and nothing else may touch an instance.
public final class PaletteWindow {
    /// Why the palette could not be built. Layer-shell's absence is not one of
    /// them — see the type's discussion.
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
    /// The empty state's height, matching `PaletteMetrics`.
    private static let emptyHeight: Int32 = 150

    /// Sends a decoded key press — or a click away — out; the window decides
    /// nothing.
    public var onCommand: ((PickerCommand) -> Void)?

    /// The panel the window hosts, for the controller to drive.
    let panel: PickerPanel

    let window: UnsafeMutablePointer<GtkWindow>
    let windowWidget: UnsafeMutablePointer<GtkWidget>
    private let keyController: OpaquePointer
    /// The full-output overlay the panel is laid out in, on a layer-shell
    /// session; nil for a plain window.
    var overlay: UnsafeMutablePointer<GtkWidget>?
    /// How tall the panel wants to be for the rows on screen, before the
    /// output's ceiling — what both kinds of window size the panel by.
    var wantedHeight = PaletteMetrics.minimumHeight
    /// The plain window's last size, so an unchanged resize is skipped.
    var lastPlainSize: (Int32, Int32)?
    /// Whether the window has been the active window since it was last shown.
    /// Losing focus dismisses only after having had it, so a compositor that is
    /// slow to activate it cannot close it on the way in.
    var hasBeenActive = false
    /// The look at focus taken once the row menu has closed.
    private var focusRecheck: LoopTimer?
    private var currentModifiers: PickerModifiers = []
    private var modifierWait = ModifierReleaseWait()
    private var modifierWaitTimer: LoopTimer?
    private var modifierReleaseActions: [() -> Void] = []

    public init() throws {
        guard let panel = PickerPanel(),
            let window = skrepka_as_window(gtk_window_new()),
            let windowWidget = skrepka_window_as_widget(window),
            let keys = gtk_event_controller_key_new()
        else { throw Unavailable.widgetCreationFailed }

        self.panel = panel
        self.window = window
        self.windowWidget = windowWidget
        self.keyController = keys

        gtk_window_set_decorated(window, 0)
        gtk_widget_add_css_class(windowWidget, "skrepka-picker")
        if GtkSession.isLayerShellAvailable {
            try buildOverlay()
        } else {
            buildPlainWindow()
        }
        connectKeys(keys)
        GtkSignal.onChange(of: "is-active", on: UnsafeMutableRawPointer(window)) { [weak self] in
            self?.activeChanged()
        }
        panel.list.onMenuClosed = { [weak self] in self?.recheckFocusSoon() }
        resize(for: [])
    }

    // MARK: - Presenting

    public func present() {
        hasBeenActive = false
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

    /// Sizes the panel to fit `documents`, clamped to the output. The
    /// arithmetic is `PaletteMetrics`', over the document's own "has a
    /// preview" flag rather than a `ClipSummary`'s.
    public func resize(for documents: [ClipDocument]) {
        wantedHeight = Self.wantedHeight(for: documents)
        if let overlay {
            // The overlay covers the output whatever the panel's size, so only
            // the panel's place in it is laid out again — the layer surface
            // itself is not re-committed, which is what could cost a key.
            gtk_widget_queue_allocate(overlay)
        } else {
            resizePlainWindow()
        }
    }

    static func wantedHeight(for documents: [ClipDocument]) -> Int32 {
        guard !documents.isEmpty else { return PaletteMetrics.chromeHeight + emptyHeight }
        let content = documents.reduce(Int32(0)) { $0 + rowHeight($1) }
        return PaletteMetrics.chromeHeight + content + PaletteMetrics.gutter * Int32(documents.count - 1)
    }

    private static func rowHeight(_ document: ClipDocument) -> Int32 {
        guard document.hasPreview, !document.isConcealed else { return PaletteMetrics.standardRowHeight }
        return PaletteMetrics.imageRowHeight
    }

    /// Dismisses the picker as Escape would, unless its row menu is open — the
    /// click or focus change that closes a menu is not one that should take
    /// the picker with it.
    func dismissFromOutside() {
        guard isVisible, !panel.list.isMenuOpen else { return }
        onCommand?(.dismiss)
    }

    /// Losing focus dismisses only after the window has had it, so a
    /// compositor that is slow to activate it cannot close it on the way in.
    /// The row menu's popup takes keyboard focus while it is open, which is
    /// why ``dismissFromOutside()`` checks for it.
    private func activeChanged() {
        guard gtk_window_is_active(window) == 0 else {
            hasBeenActive = true
            return
        }
        guard hasBeenActive else { return }
        hasBeenActive = false
        dismissFromOutside()
    }

    /// Focus that left while the row menu was open was let go — the popup
    /// takes focus itself — and nothing reports it again once the menu closes:
    /// switch apps with the menu up and the picker would stay over the app
    /// switched to. So look again once the menu has gone. Not at once: the
    /// compositor hands focus back to the window after the popup is gone, and
    /// a check in the same instant would see a window about to be active as
    /// one that lost focus.
    private func recheckFocusSoon() {
        focusRecheck?.cancel()
        focusRecheck = LoopTimer(milliseconds: 250) { [weak self] in
            guard let self else { return }
            focusRecheck?.cancel()
            focusRecheck = nil
            guard gtk_window_is_active(window) == 0 else { return }
            dismissFromOutside()
        }
    }

    // MARK: - Keys

    /// Runs `action` when Shift, Alt, Ctrl and Super are up, or after one
    /// second. The deadline keeps a lost release event from blocking paste.
    func afterModifiersReleased(_ action: @escaping () -> Void) {
        modifierReleaseActions.append(action)
        guard modifierReleaseActions.count == 1 else { return }
        guard modifierWait.begin(with: currentModifiers) == .wait else {
            finishModifierWait()
            return
        }
        modifierWaitTimer = LoopTimer(milliseconds: 1_000) { [weak self] in
            guard let self else { return }
            _ = modifierWait.timedOut()
            finishModifierWait()
        }
    }

    func recordModifiers(_ rawValue: UInt32) {
        currentModifiers = PickerModifiers(rawValue: rawValue)
        guard modifierWait.isWaiting,
            modifierWait.modifiersChanged(to: currentModifiers) == .proceed
        else { return }
        finishModifierWait()
    }

    private func finishModifierWait() {
        modifierWaitTimer?.cancel()
        modifierWaitTimer = nil
        let actions = modifierReleaseActions
        modifierReleaseActions.removeAll()
        for action in actions { action() }
    }

    private func connectKeys(_ keys: OpaquePointer) {
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        connectKeySignal(keys, "key-pressed", unsafeBitCast(Self.onKeyPressed, to: GCallback.self))
        connectKeySignal(keys, "modifiers", unsafeBitCast(Self.onModifiersChanged, to: GCallback.self))
        gtk_widget_add_controller(windowWidget, keyController)
    }

    private func connectKeySignal(_ keys: OpaquePointer, _ name: String, _ callback: GCallback) {
        skrepka_connect(
            UnsafeMutableRawPointer(keys),
            name,
            callback,
            Unmanaged.passRetained(self).toOpaque(),
            Self.onContextReleased)
    }
}

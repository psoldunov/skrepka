import CGtk4

// The layer-shell window: an overlay surface covering the whole output, with
// the panel laid out inside it where the macOS picker would put it.
//
// Why the whole output rather than a surface the size of the panel:
//
// - **Dismissing on a click away needs it.** Exclusive keyboard interactivity
//   is what delivers the first keystroke after the hotkey without a click, and
//   the protocol gives it no way to end: the seat "will always give exclusive
//   keyboard focus to the top-most layer" that asks for it. Sway does exactly
//   that, so there the surface never loses focus and there is no focus-out to
//   close on. (KWin 6.4 does let a click move focus away, and the window's
//   focus handling closes it there — but a click on the output the overlay
//   covers never reaches another window to take it.) A transparent surface
//   over everything is the one place such a click can land, and it lands on
//   ``PaletteWindow/dismissFromOutside()``. It is not passed on to the window
//   under it — nothing in Wayland can forward it — so the first click away
//   closes the picker and the second reaches the app.
// - **The shadow needs room.** A surface the size of the panel plus a margin
//   cut the drop shadow off at the margin, in a hard-edged rectangle a shade
//   darker than the wallpaper. Covering the output lets it fade out completely.
// - **The placement needs the output.** The panel hangs from a fixed top edge
//   18% down, as on the Mac, so the search field does not move as a query
//   shortens the list. A centred surface grew and shrank around its middle.
//   Laying the panel out inside the overlay places it against whichever output
//   the compositor chose, which a monitor query made before mapping cannot
//   know — a Deck docked to a television is two outputs of different sizes.
//
// Exclusive zone -1 stretches the surface over panels as well, per the
// protocol's own example of a lock screen, so a click on the taskbar dismisses
// rather than reaching the taskbar through a hole the size of it.
extension PaletteWindow {
    func buildOverlay() throws {
        guard let overlay = gtk_overlay_new(),
            let overlayCast = skrepka_as_overlay(overlay),
            let backdrop = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0),
            let click = gtk_gesture_click_new()
        else { throw Unavailable.widgetCreationFailed }

        gtk_widget_add_css_class(windowWidget, "skrepka-overlay")
        gtk_widget_set_hexpand(backdrop, 1)
        gtk_widget_set_vexpand(backdrop, 1)
        gtk_overlay_set_child(overlayCast, backdrop)
        gtk_overlay_add_overlay(overlayCast, panel.root)
        gtk_window_set_child(window, overlay)

        // Any button, and a touch: the panel sits above the backdrop in the
        // overlay, so only a press outside it reaches this gesture.
        gtk_gesture_single_set_button(skrepka_as_gesture_single(click), 0)
        PickerRowSignals.onPressed(click) { [weak self] _, _ in self?.dismissFromOutside() }
        gtk_widget_add_controller(backdrop, click)

        self.overlay = overlay
        connectPlacement(overlayCast)
        Self.raiseAsOverlay(window)
    }

    /// Overlay layer, all four edges, over the panels, exclusive keyboard. See
    /// the discussion at the top of this file.
    private static func raiseAsOverlay(_ window: UnsafeMutablePointer<GtkWindow>) {
        gtk_layer_init_for_window(window)
        gtk_layer_set_layer(window, GTK_LAYER_SHELL_LAYER_OVERLAY)
        gtk_layer_set_namespace(window, "skrepka-picker")
        for edge in [
            GTK_LAYER_SHELL_EDGE_LEFT, GTK_LAYER_SHELL_EDGE_RIGHT,
            GTK_LAYER_SHELL_EDGE_TOP, GTK_LAYER_SHELL_EDGE_BOTTOM,
        ] {
            gtk_layer_set_anchor(window, edge, 1)
        }
        gtk_layer_set_exclusive_zone(window, -1)
        gtk_layer_set_keyboard_mode(window, GTK_LAYER_SHELL_KEYBOARD_MODE_EXCLUSIVE)
    }

    // MARK: - Placing the panel

    private func connectPlacement(_ overlay: OpaquePointer) {
        skrepka_connect(
            UnsafeMutableRawPointer(overlay),
            "get-child-position",
            unsafeBitCast(Self.onChildPosition, to: GCallback.self),
            Unmanaged.passRetained(self).toOpaque(),
            Self.onContextReleased)
    }

    /// The panel's rectangle for the overlay's current size — the output's,
    /// since the surface is anchored to every edge.
    ///
    /// Never smaller than the panel measures: GTK warns on an allocation below
    /// what a widget measured, and a panel squeezed under its chrome is broken
    /// rather than small. See ``PaletteMetrics/fit(_:minimumWidth:minimumHeight:outputWidth:outputHeight:)``.
    private func panelAllocation() -> GdkRectangle? {
        guard let overlay else { return nil }
        let outputWidth = gtk_widget_get_width(overlay)
        let outputHeight = gtk_widget_get_height(overlay)
        let frame = PaletteMetrics.frame(
            wantedHeight: wantedHeight, outputWidth: outputWidth, outputHeight: outputHeight)
        var minimumWidth: Int32 = 0
        gtk_widget_measure(panel.root, GTK_ORIENTATION_HORIZONTAL, -1, &minimumWidth, nil, nil, nil)
        var minimumHeight: Int32 = 0
        let width = max(frame.width, minimumWidth)
        gtk_widget_measure(panel.root, GTK_ORIENTATION_VERTICAL, width, &minimumHeight, nil, nil, nil)
        let fitted = PaletteMetrics.fit(
            frame,
            minimumWidth: minimumWidth,
            minimumHeight: minimumHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight)
        return GdkRectangle(x: fitted.x, y: fitted.y, width: fitted.width, height: fitted.height)
    }

    /// `gboolean (*)(GtkOverlay *, GtkWidget *, GdkRectangle *, gpointer)`. A
    /// literal closure for the reason `PaletteWindow+Signals.swift` gives.
    /// Answers 1 when it filled the rectangle, which stops the default handler
    /// from placing the panel by its alignment instead.
    static let onChildPosition:
        @convention(c) (gpointer?, gpointer?, UnsafeMutablePointer<GdkRectangle>?, gpointer?) -> gboolean = {
            place(allocation: $2, data: $3)
        }

    private static func place(allocation: UnsafeMutablePointer<GdkRectangle>?, data: gpointer?) -> gboolean {
        guard let allocation, let data else { return 0 }
        let palette = Unmanaged<PaletteWindow>.fromOpaque(data).takeUnretainedValue()
        guard let rectangle = palette.panelAllocation() else { return 0 }
        allocation.pointee = rectangle
        return 1
    }
}

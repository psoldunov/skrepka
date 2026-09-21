import CGtk4

// The fallback window, for a session without wlr-layer-shell — every X11
// session, and GNOME. An ordinary undecorated toplevel the size of the panel
// plus a transparent margin for its shadow, which the panel's own CSS margin
// provides — ``PickerStyle/plainInset``.
//
// On X11 it also gets the utility hints and the keyboard grab a layer surface
// would have given it. On GNOME Wayland those are no-ops and the window is a
// best-effort plain toplevel.
extension PaletteWindow {
    func buildPlainWindow() {
        gtk_window_set_child(window, panel.root)
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

    /// Sizes the window to the panel plus its shadow margin, against the
    /// shortest monitor — a plain toplevel is placed after it is sized, so the
    /// output it lands on is not known yet.
    func resizePlainWindow() {
        let frame = PaletteMetrics.frame(
            wantedHeight: wantedHeight,
            outputWidth: 0,
            outputHeight: skrepka_smallest_monitor_height())
        let inset = PickerStyle.plainInset
        let size = (frame.width + inset * 2, frame.height + inset * 2)
        if let lastPlainSize, lastPlainSize == size { return }
        lastPlainSize = size
        gtk_window_set_default_size(window, size.0, size.1)
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

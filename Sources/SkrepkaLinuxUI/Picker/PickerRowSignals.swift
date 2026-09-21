import CGtk4

/// The three GTK callbacks the picker's rows and empty state need that carry
/// more than the two arguments ``GtkSignal`` covers: a motion controller's
/// `enter`, a click gesture's `pressed`, and a drawing area's draw function.
///
/// Each boxes a Swift closure and retains it, and GLib's notify releases it
/// when GTK is done with the controller or the source — the same arrangement
/// ``PaletteWindow`` and ``GtkSignal`` use, written once for the wider
/// signatures. Every closure runs on GTK's loop thread, so none is `Sendable`.
enum PickerRowSignals {
    /// Selects a row when the pointer enters it.
    static func onEnter(_ controller: OpaquePointer, _ run: @escaping () -> Void) {
        skrepka_connect(
            UnsafeMutableRawPointer(controller),
            "enter",
            unsafeBitCast(EnterBox.thunk, to: GCallback.self),
            Unmanaged.passRetained(EnterBox(run)).toOpaque(),
            EnterBox.release
        )
    }

    /// Fires when the pointer moves over the widget — how the picker learns the
    /// pointer has actually moved, rather than merely appeared under a still one
    /// when the surface mapped.
    static func onMotion(_ controller: OpaquePointer, _ run: @escaping () -> Void) {
        skrepka_connect(
            UnsafeMutableRawPointer(controller),
            "motion",
            unsafeBitCast(EnterBox.thunk, to: GCallback.self),
            Unmanaged.passRetained(EnterBox(run)).toOpaque(),
            EnterBox.release
        )
    }

    /// Runs `run` when a `GSimpleAction` is activated — a context-menu item.
    static func onActivate(_ action: gpointer, _ run: @escaping () -> Void) {
        skrepka_connect(
            action,
            "activate",
            unsafeBitCast(ActionBox.thunk, to: GCallback.self),
            Unmanaged.passRetained(ActionBox(run)).toOpaque(),
            ActionBox.release
        )
    }

    /// Reports a secondary-button press, in the widget's coordinates, for the
    /// context menu.
    static func onPressed(_ gesture: OpaquePointer, _ run: @escaping (Double, Double) -> Void) {
        skrepka_connect(
            UnsafeMutableRawPointer(gesture),
            "pressed",
            unsafeBitCast(PressBox.thunk, to: GCallback.self),
            Unmanaged.passRetained(PressBox(run)).toOpaque(),
            PressBox.release
        )
    }

    /// Sets a drawing area's draw function to `run`, given the Cairo context and
    /// the area's size in pixels.
    static func setDrawFunc(
        _ area: UnsafeMutablePointer<GtkWidget>,
        _ run: @escaping (OpaquePointer, Int32, Int32) -> Void
    ) {
        guard let casted = skrepka_as_drawing_area(area) else { return }
        gtk_drawing_area_set_draw_func(
            casted,
            DrawBox.thunk,
            Unmanaged.passRetained(DrawBox(run)).toOpaque(),
            DrawBox.release
        )
    }

    private final class EnterBox {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        static let thunk: @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> Void = {
            guard let data = $3 else { return }
            Unmanaged<EnterBox>.fromOpaque(data).takeUnretainedValue().run()
        }
        static let release: GClosureNotify = { data, _ in
            guard let data else { return }
            Unmanaged<EnterBox>.fromOpaque(data).release()
        }
    }

    private final class ActionBox {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        static let thunk: @convention(c) (gpointer?, gpointer?, gpointer?) -> Void = {
            guard let data = $2 else { return }
            Unmanaged<ActionBox>.fromOpaque(data).takeUnretainedValue().run()
        }
        static let release: GClosureNotify = { data, _ in
            guard let data else { return }
            Unmanaged<ActionBox>.fromOpaque(data).release()
        }
    }

    private final class PressBox {
        let run: (Double, Double) -> Void
        init(_ run: @escaping (Double, Double) -> Void) { self.run = run }
        static let thunk: @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = {
            guard let data = $4 else { return }
            Unmanaged<PressBox>.fromOpaque(data).takeUnretainedValue().run($2, $3)
        }
        static let release: GClosureNotify = { data, _ in
            guard let data else { return }
            Unmanaged<PressBox>.fromOpaque(data).release()
        }
    }

    private final class DrawBox {
        let run: (OpaquePointer, Int32, Int32) -> Void
        init(_ run: @escaping (OpaquePointer, Int32, Int32) -> Void) { self.run = run }
        static let thunk: GtkDrawingAreaDrawFunc = {
            guard let data = $4, let cairo = $1 else { return }
            Unmanaged<DrawBox>.fromOpaque(data).takeUnretainedValue().run(cairo, $2, $3)
        }
        static let release: GDestroyNotify = { data in
            guard let data else { return }
            Unmanaged<DrawBox>.fromOpaque(data).release()
        }
    }
}

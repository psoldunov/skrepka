import CGtk4

/// Swift closures behind GTK signals.
///
/// The same arrangement ``PaletteWindow`` uses, written once for the Settings
/// window's many buttons: each connection gets its own retained box in the
/// signal's user data, and GLib's closure notify releases exactly that box when
/// GTK disconnects the handler — the only moment it is sure to be done with it.
/// A box per connection rather than one shared, because GLib calls the notify
/// once per closure it destroys.
///
/// Every handler runs on GTK's main-loop thread, which is the only thread that
/// may call these, so the closures are ordinary rather than `Sendable`. The
/// `gpointer` user data is the same honest hole in concurrency checking the
/// palette describes: it makes no claim at all.
enum GtkSignal {
    /// A signal whose handler takes only the instance — `clicked` on a
    /// button, `activate` on an application.
    static func connect(_ instance: UnsafeMutableRawPointer, _ signal: String, _ run: @escaping () -> Void) {
        skrepka_connect(
            instance,
            signal,
            unsafeBitCast(Box.onSignal, to: GCallback.self),
            Unmanaged.passRetained(Box(run)).toOpaque(),
            Box.onReleased
        )
    }

    /// A property's change notification — `notify::active` on a switch.
    static func onChange(
        of property: String, on instance: UnsafeMutableRawPointer, _ run: @escaping () -> Void
    ) {
        skrepka_connect(
            instance,
            "notify::\(property)",
            unsafeBitCast(Box.onNotify, to: GCallback.self),
            Unmanaged.passRetained(Box(run)).toOpaque(),
            Box.onReleased
        )
    }

    /// `close-request` on a window. `run` answers whether to keep the window
    /// open, which is what the signal's return value means.
    static func onCloseRequest(_ window: UnsafeMutableRawPointer, _ run: @escaping () -> Bool) {
        skrepka_connect(
            window,
            "close-request",
            unsafeBitCast(Box.onCloseRequest, to: GCallback.self),
            Unmanaged.passRetained(Box(keepsOpen: run)).toOpaque(),
            Box.onReleased
        )
    }

    /// The retained box behind one connection.
    private final class Box {
        private let run: () -> Void
        private let keepsOpen: () -> Bool

        init(_ run: @escaping () -> Void) {
            self.run = run
            self.keepsOpen = { false }
        }

        init(keepsOpen: @escaping () -> Bool) {
            self.run = {}
            self.keepsOpen = keepsOpen
        }

        private static func box(_ data: gpointer?) -> Box? {
            guard let data else { return nil }
            return Unmanaged<Box>.fromOpaque(data).takeUnretainedValue()
        }

        // Literal closures forwarding to the box rather than references to
        // functions: see `PaletteWindow+Signals.swift` for the Linux compiler's
        // refusal to form a C function pointer from some `func` references.

        static let onSignal: @convention(c) (gpointer?, gpointer?) -> Void = {
            box($1)?.run()
        }

        static let onNotify: @convention(c) (gpointer?, gpointer?, gpointer?) -> Void = {
            box($2)?.run()
        }

        static let onCloseRequest: @convention(c) (gpointer?, gpointer?) -> gboolean = {
            (box($1)?.keepsOpen() ?? false) ? 1 : 0
        }

        static let onReleased: GClosureNotify = { data, _ in
            guard let data else { return }
            Unmanaged<Box>.fromOpaque(data).release()
        }
    }
}

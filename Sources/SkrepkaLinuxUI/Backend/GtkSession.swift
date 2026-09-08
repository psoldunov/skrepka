import CGtk4
import Synchronization

/// Starting GTK, and running its main loop.
///
/// A type rather than two free calls because `gtk_init()` must happen exactly
/// once, before any widget exists, and a second call is a silent no-op that
/// hides the ordering mistake rather than reporting it.
///
/// `nonisolated`, like everything else in this target. GTK is single-threaded
/// and its main loop is the thread that matters, but marking this `@MainActor`
/// would put every widget behind an isolation boundary that the C callbacks —
/// which are `@convention(c)` and therefore `nonisolated` — could only cross
/// with `MainActor.assumeIsolated`. This repository bans that, and rightly:
/// it is a claim about something the compiler cannot see. Staying nonisolated
/// makes no claim at all, which is the honest position. See ``PaletteWindow``.
public enum GtkSession {
    /// Whether GTK could open the display.
    ///
    /// `gtk_init()` cannot report failure — it aborts the process when it
    /// cannot connect — so this asks `gtk_init_check()` instead, which returns.
    /// A daemon that starts before the session's compositor has to find that
    /// out rather than die.
    @discardableResult
    public static func start() -> Bool {
        gtk_init_check() != 0
    }

    /// Whether the compositor advertises `zwlr_layer_shell_v1`.
    ///
    /// Asked before the picker is built, not while it is being built: without
    /// layer-shell there is no way to put a keyboard-driven surface over the
    /// frontmost app at all — `xdg_toplevel` has no non-activating mode and
    /// `xdg-activation-v1` only hands out tokens to raise other surfaces — so
    /// the answer decides whether the picker can exist in this session rather
    /// than how it looks.
    ///
    /// False on GNOME, whose Mutter implements no layer shell, and on X11.
    public static var isLayerShellAvailable: Bool {
        gtk_layer_is_supported() != 0
    }

    /// The layer-shell protocol version the compositor speaks, or 0.
    ///
    /// Worth reporting rather than merely checking: `keyboard_interactivity`'s
    /// `on_demand` mode arrived in version 4, and a compositor stuck on 3 can
    /// only offer `exclusive` — which changes how the picker behaves, not
    /// whether it works.
    public static var layerShellProtocolVersion: UInt32 {
        UInt32(gtk_layer_get_protocol_version())
    }

    /// Runs GTK's main loop until ``stop()``. Returns when it does.
    ///
    /// The loop is never unreffed, and that is the fix for a race rather than
    /// an oversight. ``stop()`` reads the address and then calls
    /// `g_main_loop_quit` on it; if `run()` were to unref on the way out, a
    /// `stop()` that had already read a live address and not yet made its call
    /// would quit freed memory. Publishing the loop for the process's lifetime
    /// closes that window completely. It costs one leaked `GMainLoop` at exit,
    /// which the kernel reclaims with everything else — a process has one main
    /// loop, so this does not grow.
    public static func run() {
        guard let loop = g_main_loop_new(nil, 0) else { return }
        current.store(UInt(bitPattern: loop), ordering: .releasing)
        g_main_loop_run(loop)
    }

    /// Ends the loop ``run()`` is in, from another thread.
    ///
    /// A no-op before `run()` has published a loop. After `run()` returns it
    /// quits an already-stopped loop, which GLib defines as doing nothing.
    ///
    /// **Not** for a POSIX signal handler. `g_main_loop_quit` is thread-safe —
    /// it takes the loop's context mutex — and that is exactly what makes it
    /// async-signal-unsafe: a handler that interrupts a thread already holding
    /// that mutex deadlocks. A handler that wants to stop the daemon should
    /// write to a self-pipe, or the daemon should install its handler with
    /// `g_unix_signal_add`, which dispatches on the loop instead of on the
    /// signal stack.
    public static func stop() {
        let address = current.load(ordering: .acquiring)
        guard address != 0, let loop = OpaquePointer(bitPattern: address) else { return }
        g_main_loop_quit(loop)
    }

    /// The running loop's address, so ``stop()`` has something to quit.
    ///
    /// An `Atomic<UInt>` holding a bit pattern rather than a `Mutex` holding the
    /// pointer, and that is a compiler constraint rather than a preference:
    /// `Mutex.withLock` hands its closure an `inout sending` parameter, and
    /// storing a pointer produced in the calling context into one is rejected —
    /// "'inout sending' parameter '$0' cannot be task-isolated at end of
    /// function". An address is a plain integer with no such problem.
    ///
    /// Shared state at all because `stop()` is the one thing here a caller
    /// might reasonably reach from another thread — the daemon's shutdown path
    /// — and `g_main_loop_quit` is documented as safe to call from any *thread*.
    /// Zero means "not started". It is never set back to zero: see ``run()``.
    private static let current = Atomic<UInt>(0)
}

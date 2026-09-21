import CGtk4

/// A repeating timer on GTK's main loop.
final class LoopTimer {
    private var id: guint

    init(seconds: UInt32, _ run: @escaping () -> Void) {
        id = g_timeout_add_seconds_full(
            G_PRIORITY_DEFAULT,
            seconds,
            LoopCallback.onTimeout,
            Unmanaged.passRetained(LoopCallback(run)).toOpaque(),
            LoopCallback.onReleased
        )
    }

    /// The same, at millisecond resolution, for a delay a person should not
    /// notice.
    init(milliseconds: UInt32, _ run: @escaping () -> Void) {
        id = g_timeout_add_full(
            G_PRIORITY_DEFAULT,
            milliseconds,
            LoopCallback.onTimeout,
            Unmanaged.passRetained(LoopCallback(run)).toOpaque(),
            LoopCallback.onReleased
        )
    }

    /// Idempotent. The closure is released as the source goes.
    func cancel() {
        guard id != 0 else { return }
        g_source_remove(id)
        id = 0
    }

    deinit {
        cancel()
    }
}

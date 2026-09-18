import CGtk4

/// A closure behind a GLib source, and the three C entry points that reach it.
///
/// Not generic, because a `@convention(c)` function cannot be: the generic
/// part stays inside the closure.
final class LoopCallback {
    let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }

    private static func callback(_ data: gpointer?) -> LoopCallback? {
        guard let data else { return nil }
        return Unmanaged<LoopCallback>.fromOpaque(data).takeUnretainedValue()
    }

    /// `GUnixFDSourceFunc`: the descriptor is readable. Keeps the source.
    static let onDescriptorReadable: @convention(c) (Int32, GIOCondition, gpointer?) -> gboolean = {
        callback($2)?.run()
        return 1
    }

    /// `GSourceFunc`, for a timeout. Keeps the source; cancelling removes it.
    static let onTimeout: @convention(c) (gpointer?) -> gboolean = {
        callback($0)?.run()
        return 1
    }

    /// Balances the `passRetained` the source was given.
    static let onReleased: GDestroyNotify = { data in
        guard let data else { return }
        Unmanaged<LoopCallback>.fromOpaque(data).release()
    }
}

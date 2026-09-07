import CWaylandClient
import Foundation

/// Asks a Wayland compositor what it advertises, and disconnects.
///
/// One round trip and nothing else. It exists so ``SessionProbe`` can decide
/// from evidence rather than from `WAYLAND_DISPLAY`, and so the deciding half
/// of that — ``SessionProbe/decide(waylandGlobals:waylandDisplay:x11Display:desktop:)``
/// — stays a pure function over a list of strings that a test can supply.
enum WaylandGlobals {
    /// Interface names the compositor advertises, in the order it announced
    /// them.
    ///
    /// Empty when there is no compositor to ask, which is the same answer as a
    /// compositor advertising nothing — and correctly so: both mean "no
    /// data-control global here".
    ///
    /// - Parameter displayName: the socket to connect to, or nil to let
    ///   libwayland read `WAYLAND_DISPLAY` itself.
    static func enumerate(displayName: String? = nil) -> [String] {
        guard let display = wl_display_connect(displayName) else { return [] }
        defer { wl_display_disconnect(display) }
        guard let registry = wl_display_get_registry(display) else { return [] }
        defer { wl_registry_destroy(registry) }

        let collector = Collector()
        var listener = wl_registry_listener(
            global: { data, _, _, interface, _ in
                guard let data, let interface else { return }
                Unmanaged<Collector>.fromOpaque(data).takeUnretainedValue()
                    .names.append(String(cString: interface))
            },
            // A global removed during the one round trip this makes is a global
            // that was never usable. Nothing to undo.
            global_remove: { _, _, _ in }
        )

        // The listener has to outlive every event dispatched against it, so the
        // round trip happens inside the pointer's scope rather than after it.
        // libwayland keeps the pointer, not a copy.
        withUnsafePointer(to: &listener) { pointer in
            wl_registry_add_listener(registry, pointer, Unmanaged.passUnretained(collector).toOpaque())
            // Blocks until the compositor has answered the registry's initial
            // burst of `global` events, which is the whole point: without it
            // the list is whatever happened to have arrived.
            wl_display_roundtrip(display)
        }

        return collector.names
    }

    /// Somewhere for a C callback to put its answers.
    ///
    /// A class rather than a captured array because a `@convention(c)` function
    /// captures nothing — the object travels as the listener's `data` pointer
    /// and comes back through `Unmanaged`. Never escapes this file, and every
    /// touch of it happens on the one thread that called ``enumerate(displayName:)``.
    private final class Collector {
        var names: [String] = []
    }
}

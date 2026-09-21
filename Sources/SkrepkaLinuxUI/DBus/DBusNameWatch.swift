import CGtk4

/// Watches a well-known name on an existing connection.
public final class DBusNameWatch {
    private var identifier: UInt32 = 0

    public init(
        connection: DBusConnection,
        name: String,
        appeared: @escaping (String) -> Void,
        vanished: @escaping () -> Void
    ) {
        let callback = Callback(appeared: appeared, vanished: vanished)
        identifier = g_bus_watch_name_on_connection(
            connection.raw,
            name,
            G_BUS_NAME_WATCHER_FLAGS_NONE,
            Callback.onAppeared,
            Callback.onVanished,
            Unmanaged.passRetained(callback).toOpaque(),
            Callback.onReleased
        )
    }

    public func cancel() {
        guard identifier != 0 else { return }
        g_bus_unwatch_name(identifier)
        identifier = 0
    }

    deinit {
        cancel()
    }

    private final class Callback {
        let appeared: (String) -> Void
        let vanished: () -> Void

        init(appeared: @escaping (String) -> Void, vanished: @escaping () -> Void) {
            self.appeared = appeared
            self.vanished = vanished
        }

        static let onAppeared: GBusNameAppearedCallback = { _, _, owner, data in
            guard let owner, let data else { return }
            Unmanaged<Callback>.fromOpaque(data).takeUnretainedValue().appeared(String(cString: owner))
        }

        static let onVanished: GBusNameVanishedCallback = { _, _, data in
            guard let data else { return }
            Unmanaged<Callback>.fromOpaque(data).takeUnretainedValue().vanished()
        }

        static let onReleased: GDestroyNotify = { data in
            guard let data else { return }
            Unmanaged<Callback>.fromOpaque(data).release()
        }
    }
}

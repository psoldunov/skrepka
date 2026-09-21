import CGtk4

/// Owns a well-known name for as long as this object lives.
public final class DBusNameOwner {
    private var identifier: UInt32 = 0

    public init(
        connection: DBusConnection,
        name: String,
        acquired: @escaping () -> Void,
        lost: @escaping () -> Void
    ) {
        let callback = Callback(acquired: acquired, lost: lost)
        identifier = g_bus_own_name_on_connection(
            connection.raw,
            name,
            G_BUS_NAME_OWNER_FLAGS_NONE,
            Callback.onAcquired,
            Callback.onLost,
            Unmanaged.passRetained(callback).toOpaque(),
            Callback.onReleased
        )
    }

    public func cancel() {
        guard identifier != 0 else { return }
        g_bus_unown_name(identifier)
        identifier = 0
    }

    deinit {
        cancel()
    }

    private final class Callback {
        let acquired: () -> Void
        let lost: () -> Void

        init(acquired: @escaping () -> Void, lost: @escaping () -> Void) {
            self.acquired = acquired
            self.lost = lost
        }

        static let onAcquired: GBusNameAcquiredCallback = { _, _, data in
            guard let data else { return }
            Unmanaged<Callback>.fromOpaque(data).takeUnretainedValue().acquired()
        }

        static let onLost: GBusNameLostCallback = { _, _, data in
            guard let data else { return }
            Unmanaged<Callback>.fromOpaque(data).takeUnretainedValue().lost()
        }

        static let onReleased: GDestroyNotify = { data in
            guard let data else { return }
            Unmanaged<Callback>.fromOpaque(data).release()
        }
    }
}

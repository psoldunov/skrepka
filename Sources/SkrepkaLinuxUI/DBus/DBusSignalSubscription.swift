import CGtk4

/// A GDBus signal subscription whose callback runs on GTK's main-loop thread.
public final class DBusSignalSubscription {
    private let connection: DBusConnection
    private var identifier: UInt32 = 0

    public init(
        connection: DBusConnection,
        sender: String? = nil,
        interface: String,
        member: String,
        path: String? = nil,
        receive: @escaping (String, DBusValue) -> Void
    ) {
        self.connection = connection
        let callback = Callback(receive)
        identifier = g_dbus_connection_signal_subscribe(
            connection.raw,
            sender,
            interface,
            member,
            path,
            nil,
            G_DBUS_SIGNAL_FLAGS_NONE,
            Callback.onSignal,
            Unmanaged.passRetained(callback).toOpaque(),
            Callback.onReleased
        )
    }

    public func cancel() {
        guard identifier != 0 else { return }
        g_dbus_connection_signal_unsubscribe(connection.raw, identifier)
        identifier = 0
    }

    deinit {
        cancel()
    }

    private final class Callback {
        let receive: (String, DBusValue) -> Void

        init(_ receive: @escaping (String, DBusValue) -> Void) {
            self.receive = receive
        }

        private static func receiveSignal(
            _ signalName: UnsafePointer<CChar>?,
            parameters: OpaquePointer?,
            data: gpointer?
        ) {
            guard
                let signalName,
                let parameters,
                let data,
                let value = DBusValue.parse(parameters)
            else { return }
            let callback = Unmanaged<Callback>.fromOpaque(data).takeUnretainedValue()
            callback.receive(String(cString: signalName), value)
        }

        static let onSignal: GDBusSignalCallback = {
            receiveSignal($4, parameters: $5, data: $6)
        }

        static let onReleased: GDestroyNotify = { data in
            guard let data else { return }
            Unmanaged<Callback>.fromOpaque(data).release()
        }
    }
}

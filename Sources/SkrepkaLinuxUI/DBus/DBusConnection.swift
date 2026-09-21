import CGtk4

public struct DBusError: Error, CustomStringConvertible, Sendable {
    public let name: String?
    public let message: String

    public var description: String {
        name.map { "\($0): \(message)" } ?? message
    }

    static func take(_ error: UnsafeMutablePointer<GError>?) -> DBusError {
        guard let error else { return DBusError(name: nil, message: "unknown GDBus error") }
        defer { g_error_free(error) }
        let namePointer = g_dbus_error_get_remote_error(error)
        let name = namePointer.map { String(cString: $0) }
        g_free(namePointer)
        return DBusError(name: name, message: String(cString: error.pointee.message))
    }

    public var isUnknownMember: Bool {
        name == "org.freedesktop.DBus.Error.UnknownMethod"
            || name == "org.freedesktop.DBus.Error.UnknownInterface"
    }
}

/// One session-bus connection, dispatched by the default GLib main context.
public final class DBusConnection {
    let raw: OpaquePointer

    /// The process-wide shared session connection — the one GTK and
    /// GApplication use too.
    public init() throws {
        var error: UnsafeMutablePointer<GError>?
        guard let connection = g_bus_get_sync(G_BUS_TYPE_SESSION, nil, &error) else {
            throw DBusError.take(error)
        }
        raw = connection
    }

    private init(raw: OpaquePointer) {
        self.raw = raw
    }

    /// A session connection of this client's own, separate from the shared
    /// one.
    ///
    /// For a client whose first message to a service has to be the first that
    /// service ever receives from this bus name — see ``GlobalShortcuts``.
    /// Dispatched by the default main context like the shared one, because it
    /// is made on GTK's loop thread.
    public static func privateSession() throws -> DBusConnection {
        var error: UnsafeMutablePointer<GError>?
        guard let address = g_dbus_address_get_for_bus_sync(G_BUS_TYPE_SESSION, nil, &error) else {
            throw DBusError.take(error)
        }
        defer { g_free(address) }
        let flags = GDBusConnectionFlags(
            rawValue: G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT.rawValue
                | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION.rawValue)
        guard let connection = g_dbus_connection_new_for_address_sync(address, flags, nil, nil, &error) else {
            throw DBusError.take(error)
        }
        return DBusConnection(raw: connection)
    }

    deinit {
        g_object_unref(UnsafeMutableRawPointer(raw))
    }

    public var uniqueName: String {
        guard let name = g_dbus_connection_get_unique_name(raw) else { return "" }
        return String(cString: name)
    }

    public func call(
        destination: String,
        path: String,
        interface: String,
        method: String,
        parameters: DBusValue = .tuple([]),
        completion: @escaping (Result<DBusValue, DBusError>) -> Void
    ) {
        let callback = CallCallback(completion)
        g_dbus_connection_call(
            raw,
            destination,
            path,
            interface,
            method,
            parameters.makeVariant(),
            nil,
            G_DBUS_CALL_FLAGS_NONE,
            -1,
            nil,
            CallCallback.onReply,
            Unmanaged.passRetained(callback).toOpaque()
        )
    }

    public func emit(
        path: String, interface: String, signal: String, parameters: DBusValue
    ) throws {
        var error: UnsafeMutablePointer<GError>?
        guard
            g_dbus_connection_emit_signal(
                raw, nil, path, interface, signal, parameters.makeVariant(), &error) != 0
        else { throw DBusError.take(error) }
    }

    private final class CallCallback {
        let completion: (Result<DBusValue, DBusError>) -> Void

        init(_ completion: @escaping (Result<DBusValue, DBusError>) -> Void) {
            self.completion = completion
        }

        static let onReply: GAsyncReadyCallback = { source, result, data in
            guard let source, let result, let data else { return }
            let callback = Unmanaged<CallCallback>.fromOpaque(data).takeRetainedValue()
            var error: UnsafeMutablePointer<GError>?
            guard let reply = g_dbus_connection_call_finish(OpaquePointer(source), result, &error) else {
                callback.completion(.failure(DBusError.take(error)))
                return
            }
            defer { g_variant_unref(reply) }
            guard let value = DBusValue.parse(reply) else {
                callback.completion(.failure(DBusError(name: nil, message: "unsupported D-Bus reply")))
                return
            }
            callback.completion(.success(value))
        }
    }
}

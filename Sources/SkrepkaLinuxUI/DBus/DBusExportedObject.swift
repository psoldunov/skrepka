import CGtk4

public final class DBusInvocation {
    private let raw: OpaquePointer
    private var answered = false

    init(_ raw: OpaquePointer) {
        self.raw = raw
    }

    public func returnValue(_ value: DBusValue = .tuple([])) {
        guard !answered else { return }
        answered = true
        g_dbus_method_invocation_return_value(raw, value.makeVariant())
    }

    public func returnError(name: String, message: String) {
        guard !answered else { return }
        answered = true
        g_dbus_method_invocation_return_dbus_error(raw, name, message)
    }
}

/// One interface exported at one object path.
public final class DBusExportedObject {
    public typealias MethodHandler = (String, DBusValue, DBusInvocation) -> Void
    public typealias PropertyHandler = (String) -> DBusValue?

    private let connection: DBusConnection
    private let node: UnsafeMutablePointer<GDBusNodeInfo>
    private var registration: UInt32 = 0

    public init(
        connection: DBusConnection,
        path: String,
        interface: String,
        xml: String,
        method: @escaping MethodHandler,
        property: @escaping PropertyHandler
    ) throws {
        self.connection = connection
        var error: UnsafeMutablePointer<GError>?
        guard let node = g_dbus_node_info_new_for_xml(xml, &error) else {
            throw DBusError.take(error)
        }
        self.node = node
        guard let info = g_dbus_node_info_lookup_interface(node, interface) else {
            throw DBusError(name: nil, message: "introspection XML has no \(interface)")
        }
        let handlers = Handlers(method: method, property: property)
        registration = skrepka_dbus_register_object(
            connection.raw,
            path,
            info,
            Handlers.onMethod,
            Handlers.onProperty,
            Unmanaged.passRetained(handlers).toOpaque(),
            Handlers.onReleased,
            &error
        )
        guard registration != 0 else { throw DBusError.take(error) }
    }

    deinit {
        if registration != 0 {
            g_dbus_connection_unregister_object(connection.raw, registration)
        }
        g_dbus_node_info_unref(node)
    }

    private final class Handlers {
        let method: MethodHandler
        let property: PropertyHandler

        init(method: @escaping MethodHandler, property: @escaping PropertyHandler) {
            self.method = method
            self.property = property
        }

        private static func callMethod(
            _ methodName: UnsafePointer<CChar>?,
            parameters: OpaquePointer?,
            invocation: OpaquePointer?,
            data: gpointer?
        ) {
            guard
                let methodName,
                let parameters,
                let invocation,
                let data,
                let value = DBusValue.parse(parameters)
            else { return }
            let handlers = Unmanaged<Handlers>.fromOpaque(data).takeUnretainedValue()
            handlers.method(String(cString: methodName), value, DBusInvocation(invocation))
        }

        private static func readProperty(
            _ propertyName: UnsafePointer<CChar>?, data: gpointer?
        ) -> OpaquePointer? {
            guard let propertyName, let data else { return nil }
            let handlers = Unmanaged<Handlers>.fromOpaque(data).takeUnretainedValue()
            return handlers.property(String(cString: propertyName))?.makeVariant()
        }

        static let onMethod: SkrepkaDBusMethodCall = {
            callMethod($4, parameters: $5, invocation: $6, data: $7)
        }

        static let onProperty: SkrepkaDBusGetProperty = {
            readProperty($4, data: $6)
        }

        static let onReleased: GDestroyNotify = { data in
            guard let data else { return }
            Unmanaged<Handlers>.fromOpaque(data).release()
        }
    }
}

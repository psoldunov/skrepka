import Glibc

/// KDE StatusNotifierItem plus its dbusmenu, on GTK's main-loop thread.
public final class TrayIcon {
    public var onActivate: (() -> Void)?
    public var onMenuItem: ((TrayMenu.ItemID) -> Void)?
    public var onActivationToken: ((String) -> Void)?

    public private(set) var isHosted = false
    public private(set) var startupError: String?

    private let connection: DBusConnection
    private let busName: String
    private let pixmaps: [TrayPixmap]
    var menu: TrayMenu
    private var problem: String?
    var revision: UInt32 = 1
    private var itemExport: DBusExportedObject?
    private var menuExport: DBusExportedObject?
    private var nameOwner: DBusNameOwner?
    private var watcher: DBusNameWatch?
    private var watcherOwner: String?
    private var ownsName = false

    public init(menu: TrayMenu) throws {
        connection = try DBusConnection()
        self.menu = menu
        busName = "org.kde.StatusNotifierItem-\(getpid())-1"
        pixmaps = [22, 32, 48].compactMap(TrayPixmap.render)
    }

    public func start() {
        guard nameOwner == nil else { return }
        do {
            try exportObjects()
        } catch {
            startupError = String(describing: error)
            return
        }
        nameOwner = DBusNameOwner(
            connection: connection,
            name: busName,
            acquired: { [weak self] in
                self?.ownsName = true
                self?.registerWithWatcher()
            },
            lost: { [weak self] in
                self?.ownsName = false
                self?.isHosted = false
            }
        )
        watcher = DBusNameWatch(
            connection: connection,
            name: "org.kde.StatusNotifierWatcher",
            appeared: { [weak self] owner in
                self?.watcherOwner = owner
                self?.registerWithWatcher()
            },
            vanished: { [weak self] in
                self?.watcherOwner = nil
                self?.isHosted = false
            }
        )
    }

    public func update(menu: TrayMenu) {
        self.menu = menu
        revision &+= 1
        emit(
            path: "/MenuBar",
            interface: TrayIntrospection.menuInterface,
            signal: "LayoutUpdated",
            parameters: .tuple([.uint32(revision), .int32(0)])
        )
        let updates = menu.items.map { item in
            DBusValue.tuple([
                .int32(item.id.rawValue),
                .dictionary(menu.properties(for: item.id) ?? [:]),
            ])
        }
        emit(
            path: "/MenuBar",
            interface: TrayIntrospection.menuInterface,
            signal: "ItemsPropertiesUpdated",
            parameters: .tuple([
                .array(elementSignature: "(ia{sv})", values: updates),
                .array(elementSignature: "(ias)", values: []),
            ])
        )
    }

    public func setProblem(_ headline: String?) {
        guard headline != problem else { return }
        problem = headline
        let properties = TrayProperties(problem: problem, pixmaps: pixmaps)
        emit(
            path: "/StatusNotifierItem",
            interface: TrayIntrospection.itemInterface,
            signal: "NewStatus",
            parameters: .tuple([.string(properties.status)])
        )
        emit(
            path: "/StatusNotifierItem",
            interface: TrayIntrospection.itemInterface,
            signal: "NewToolTip",
            parameters: .tuple([])
        )
    }

    private func exportObjects() throws {
        itemExport = try DBusExportedObject(
            connection: connection,
            path: "/StatusNotifierItem",
            interface: TrayIntrospection.itemInterface,
            xml: TrayIntrospection.item,
            method: { [weak self] name, parameters, invocation in
                self?.handleItemMethod(name, parameters: parameters, invocation: invocation)
            },
            property: { [weak self] name in
                guard let self else { return nil }
                return TrayProperties(problem: problem, pixmaps: pixmaps).value(named: name)
            }
        )
        menuExport = try DBusExportedObject(
            connection: connection,
            path: "/MenuBar",
            interface: TrayIntrospection.menuInterface,
            xml: TrayIntrospection.menu,
            method: { [weak self] name, parameters, invocation in
                self?.handleMenuMethod(name, parameters: parameters, invocation: invocation)
            },
            property: { name in
                switch name {
                case "Version": .uint32(3)
                case "TextDirection": .string("ltr")
                case "Status": .string("normal")
                case "IconThemePath": .array(elementSignature: "s", values: [])
                default: nil
                }
            }
        )
    }

    private func emit(
        path: String, interface: String, signal: String, parameters: DBusValue
    ) {
        do {
            try connection.emit(
                path: path, interface: interface, signal: signal, parameters: parameters)
        } catch {
            startupError = String(describing: error)
        }
    }

    private func registerWithWatcher() {
        guard ownsName, let owner = watcherOwner else { return }
        isHosted = false
        connection.call(
            destination: "org.kde.StatusNotifierWatcher",
            path: "/StatusNotifierWatcher",
            interface: "org.kde.StatusNotifierWatcher",
            method: "RegisterStatusNotifierItem",
            parameters: .tuple([.string(busName)])
        ) { [weak self] result in
            guard let self, watcherOwner == owner else { return }
            switch result {
            case .success:
                isHosted = true
                startupError = nil
            case .failure(let error):
                isHosted = false
                startupError = error.description
            }
        }
    }

    private func handleItemMethod(
        _ name: String,
        parameters: DBusValue,
        invocation: DBusInvocation
    ) {
        switch name {
        case "Activate", "SecondaryActivate": onActivate?()
        case "ProvideXdgActivationToken":
            if case .tuple(let values) = parameters, let token = values.first?.stringValue {
                onActivationToken?(token)
            }
        default: break
        }
        invocation.returnValue()
    }
}

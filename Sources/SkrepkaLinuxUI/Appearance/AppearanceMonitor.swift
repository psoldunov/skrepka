import CGtk4

/// Tracks the Settings portal, falling back to GTK when no portal answers.
public final class AppearanceMonitor {
    public var onChange: ((AppearancePreference) -> Void)?
    public private(set) var current: AppearancePreference

    private var connection: DBusConnection?
    private var subscription: DBusSignalSubscription?
    private var started = false

    public init() {
        current = AppearancePreference(
            colorScheme: skrepka_gtk_prefers_dark() != 0 ? .dark : .noPreference,
            accent: nil
        )
    }

    public func start() {
        guard !started else { return }
        started = true
        onChange?(current)
        do {
            let connection = try DBusConnection()
            self.connection = connection
            subscription = DBusSignalSubscription(
                connection: connection,
                sender: "org.freedesktop.portal.Desktop",
                interface: "org.freedesktop.portal.Settings",
                member: "SettingChanged",
                path: "/org/freedesktop/portal/desktop"
            ) { [weak self] _, value in self?.receive(value) }
            read("color-scheme", using: "ReadOne")
            read("accent-color", using: "ReadOne")
        } catch {
            return
        }
    }

    private func read(_ key: String, using method: String) {
        connection?.call(
            destination: "org.freedesktop.portal.Desktop",
            path: "/org/freedesktop/portal/desktop",
            interface: "org.freedesktop.portal.Settings",
            method: method,
            parameters: .tuple([
                .string("org.freedesktop.appearance"),
                .string(key),
            ])
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value): apply(key: key, value: value)
            case .failure where method == "ReadOne": read(key, using: "Read")
            case .failure: break
            }
        }
    }

    private func receive(_ value: DBusValue) {
        guard let (key, setting) = AppearanceParser.settingChange(value) else { return }
        apply(key: key, value: setting)
    }

    private func apply(key: String, value: DBusValue) {
        let updated: AppearancePreference
        switch key {
        case "color-scheme":
            guard let scheme = AppearanceParser.colorScheme(from: value) else { return }
            updated = AppearancePreference(colorScheme: scheme, accent: current.accent)
        case "accent-color":
            updated = AppearancePreference(
                colorScheme: current.colorScheme,
                accent: AppearanceParser.accent(from: value)
            )
        default: return
        }
        publish(updated)
    }

    private func publish(_ preference: AppearancePreference) {
        guard preference != current else { return }
        current = preference
        onChange?(preference)
    }
}

import CGtk4

/// The Sync pane's widgets: a banner, this device, and its devices — the
/// macOS Sync pane's two cards, in GTK.
///
/// It decides nothing. ``render(_:)`` copies a ``SyncPaneState`` onto the
/// widgets, and every control reports what the user did through one of the
/// `on…` closures. `nonisolated` and reached from C callbacks, like
/// ``PaletteWindow``: every method runs on GTK's main-loop thread and nothing
/// else may touch an instance.
final class SyncPane {
    var onPairingSwitch: ((Bool) -> Void)?
    var onPair: ((String) -> Void)?
    var onUnpair: ((String) -> Void)?
    var onLivePush: ((String, Bool) -> Void)?
    var onSyncNow: (() -> Void)?
    var onDismissBanner: (() -> Void)?

    /// The pane's outermost widget, for the window to put in a scroller.
    let root: GtkWidgetPointer

    private let banner: SyncBanner
    private let thisDevice: ThisDeviceCard
    private let devices: DeviceList

    init() throws {
        guard let root = GtkBuild.box(vertical: true, spacing: 12),
            let deviceHeading = GtkBuild.label("This device", classes: [SettingsStyle.heading]),
            let devicesHeading = GtkBuild.label("Devices", classes: [SettingsStyle.heading]),
            let privacy = GtkBuild.label(
                """
                Skrepka shares history with devices you pair with, over the local \
                network only. Nothing is sent to a server.
                """,
                classes: [SettingsStyle.secondary],
                wraps: true
            )
        else { throw SettingsError.widgetCreationFailed }
        GtkBuild.margins(root, vertical: 20, horizontal: 20)

        self.root = root
        self.banner = try SyncBanner()
        self.thisDevice = try ThisDeviceCard()
        self.devices = try DeviceList()

        let children = [
            banner.widget, deviceHeading, thisDevice.widget, privacy, devicesHeading, devices.widget,
        ]
        for child in children {
            GtkBuild.append(child, to: root)
        }
        connect()
    }

    private func connect() {
        thisDevice.onPairingSwitch = { [weak self] isOn in self?.onPairingSwitch?(isOn) }
        banner.onDismiss = { [weak self] in self?.onDismissBanner?() }
        devices.onPair = { [weak self] id in self?.onPair?(id) }
        devices.onUnpair = { [weak self] id in self?.onUnpair?(id) }
        devices.onLivePush = { [weak self] id, isOn in self?.onLivePush?(id, isOn) }
        devices.onSyncNow = { [weak self] in self?.onSyncNow?() }
    }

    func render(_ state: SyncPaneState) {
        banner.render(state.banner)
        thisDevice.render(name: state.deviceName, code: state.deviceCode, pairing: state.pairingSwitch)
        devices.render(state)
    }
}

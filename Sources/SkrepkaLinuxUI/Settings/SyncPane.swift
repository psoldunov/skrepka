import CGtk4

/// The Sync pane's widgets: a banner, the sharing switch, this device, and
/// its devices — the macOS Sync pane's cards, in GTK.
///
/// It decides nothing. ``render(_:)`` copies a ``SyncPaneState`` onto the
/// widgets, ``renderSharing(_:)`` a ``SharingSwitchState``, and every control
/// reports what the user did through one of the `on…` closures. `nonisolated`
/// and reached from C callbacks, like ``PaletteWindow``: every method runs on
/// GTK's main-loop thread and nothing else may touch an instance.
final class SyncPane {
    var onPairingSwitch: ((Bool) -> Void)?
    var onPair: ((String) -> Void)?
    var onUnpair: ((String) -> Void)?
    var onLivePush: ((String, Bool) -> Void)?
    var onSyncNow: (() -> Void)?
    var onDismissBanner: (() -> Void)?
    /// The master switch, flipped to the value given.
    var onSharing: ((Bool) -> Void)?

    let page: SettingsPage

    private let banner: SyncBanner
    private let sharing: SettingsSwitchRow
    private let thisDevice: ThisDeviceCard
    private let devices: DeviceList

    init() throws {
        let page = try SettingsPage(title: SettingsSection.sync.title)
        let sharingCard = try SettingsCard(title: "Sharing")
        let sharing = try SettingsSwitchRow(
            title: "Share history with paired devices",
            icon: ["emblem-shared-symbolic", "emblem-synchronizing-symbolic", "view-refresh-symbolic"])
        sharingCard.add(sharing.row.widget)

        self.page = page
        self.banner = try SyncBanner()
        self.sharing = sharing
        self.thisDevice = try ThisDeviceCard()
        self.devices = try DeviceList()

        for child in [banner.widget, sharingCard.widget, thisDevice.widget, devices.widget] {
            page.append(child)
        }
        connect()
    }

    private func connect() {
        thisDevice.onPairingSwitch = { [weak self] isOn in self?.onPairingSwitch?(isOn) }
        sharing.onToggle = { [weak self] isOn in self?.onSharing?(isOn) }
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

    func renderSharing(_ state: SharingSwitchState) {
        sharing.render(isOn: state.isOn, isEnabled: state.isEnabled, subtitle: state.subtitle)
    }
}

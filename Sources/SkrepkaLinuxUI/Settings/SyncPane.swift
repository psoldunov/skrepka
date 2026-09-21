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
    /// The file-size limit chosen, in bytes; 0 stops file contents syncing.
    var onFileLimit: ((Int) -> Void)?

    let page: SettingsPage

    private let banner: SyncBanner
    private let sharing: SettingsSwitchRow
    private let fileLimit: SettingsDropDownRow
    private var drawnFileLimit: FileLimitState?
    private let thisDevice: ThisDeviceCard
    private let devices: DeviceList

    init() throws {
        let page = try SettingsPage(title: SettingsSection.sync.title)
        let sharingCard = try SettingsCard(title: "Sharing")
        let sharing = try SettingsSwitchRow(
            title: "Share history with paired devices",
            icon: ["emblem-shared-symbolic", "emblem-synchronizing-symbolic", "view-refresh-symbolic"])
        sharingCard.add(sharing.row.widget)
        let fileLimit = try SettingsDropDownRow(
            title: "Sync files up to",
            subtitle: "Larger copies of files reach other devices as their names.",
            icon: ["document-send-symbolic", "folder-documents-symbolic", "text-x-generic-symbolic"])
        sharingCard.add(fileLimit.row.widget)

        self.page = page
        self.banner = try SyncBanner()
        self.sharing = sharing
        self.fileLimit = fileLimit
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
        fileLimit.onSelect = { [weak self] index in
            guard let values = self?.drawnFileLimit?.choice.values, values.indices.contains(index) else {
                return
            }
            self?.onFileLimit?(values[index])
        }
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

    func renderFileLimit(_ state: FileLimitState) {
        guard state != drawnFileLimit else { return }
        drawnFileLimit = state
        fileLimit.render(state.choice, isEnabled: state.isEnabled)
    }
}

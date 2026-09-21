import SkrepkaIPC

/// The Sync pane's master switch: "Share history with paired devices".
public struct SharingSwitchState: Sendable, Hashable {
    public let isOn: Bool
    public let isEnabled: Bool
    public let subtitle: String

    /// On as the daemon says — or as the user last put it while that flip is
    /// on its way. Off and disabled, saying why, when the daemon was started
    /// with `--no-sync` or cannot be changed from here.
    public init(_ model: PreferencesModel) {
        guard let document = model.document else {
            isOn = false
            isEnabled = false
            subtitle = Self.unavailableSubtitle(model.availability)
            return
        }
        guard !document.sync.isLockedOff else {
            isOn = false
            isEnabled = false
            subtitle = "skrepkad was started with --no-sync, which no setting overrides."
            return
        }
        let wanted = model.inFlight.last { $0.syncEnabled != nil }?.syncEnabled
        isOn = wanted ?? document.sync.isEnabled
        isEnabled = true
        subtitle =
            isOn
            ? "Paired devices send and receive history over this network."
            : "Off. This device keeps its history to itself; pairings are kept."
    }

    private static func unavailableSubtitle(_ availability: PreferencesModel.Availability) -> String {
        switch availability {
        case .loading: "Asking skrepkad…"
        case .unsupported: "Update skrepkad to turn sharing on or off from here."
        case .unreachable, .ready: "Unavailable while skrepkad cannot be reached."
        }
    }
}

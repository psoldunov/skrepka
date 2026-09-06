import Foundation

/// Live push for one paired peer: the platform default, and whatever the user
/// chose instead.
///
/// Two fields rather than one resolved boolean because the settings row shows
/// both — the switch reflects ``isOn``, and the explanation under it reflects
/// ``reason``, which is only worth showing while the user has not overridden it.
/// Collapsing them at the storage boundary would leave the row unable to say
/// why a switch it is drawing as off is off.
public struct LivePushSetting: Sendable, Hashable {
    /// What design §3 says for these two platforms.
    public let reason: LivePushDefault

    /// What the user chose for this peer.
    ///
    /// Stored against the paired-device record rather than in preferences, so
    /// forgetting a peer forgets the choice with it — see
    /// ``PairedDeviceStoring/setLivePushChoice(_:for:)``. A preference keyed by
    /// device identifier would outlive the pairing and silently re-apply if the
    /// same machine ever paired again.
    public let choice: LivePushChoice

    public init(reason: LivePushDefault, choice: LivePushChoice) {
        self.reason = reason
        self.choice = choice
    }

    /// The setting for a pair, given what the store holds for it.
    public init(
        local: PeerPlatform,
        remote: PeerPlatform,
        choice: LivePushChoice = .followsPlatformDefault
    ) {
        self.init(reason: .between(local: local, remote: remote), choice: choice)
    }

    public var isOn: Bool {
        switch choice {
        case .followsPlatformDefault: reason.isOn
        case .on: true
        case .off: false
        }
    }

    /// Whether the user has taken this peer off the platform default, which is
    /// when a row should stop explaining the default and start reflecting the
    /// choice.
    public var isOverridden: Bool { choice != .followsPlatformDefault }
}

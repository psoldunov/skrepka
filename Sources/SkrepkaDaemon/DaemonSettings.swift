import Foundation
import SkrepkaCore
import SkrepkaIPC

/// What `config.json` holds: the settings a user changes, and nothing the
/// daemon works out for itself.
///
/// ```json
/// {"version":1,"retention":{"maximumItems":500,"maximumAgeDays":30},"sync":{"enabled":true}}
/// ```
///
/// Limits use 0 for "no limit", as ``SkrepkaIPC/SettingsDocument`` does, so a
/// stored "unlimited" is a choice rather than an absent key that reads back as
/// the default. The defaults are exactly what the daemon did before the file
/// existed — 500 entries, 30 days, sync on — so a machine with no file behaves
/// as it always has.
struct DaemonSettings: Codable, Sendable, Hashable {
    /// The format this build writes.
    static let currentVersion = 1

    struct Retention: Codable, Sendable, Hashable {
        let maximumItems: Int
        let maximumAgeDays: Int
    }

    struct Sync: Codable, Sendable, Hashable {
        let enabled: Bool
    }

    let version: Int
    let retention: Retention
    let sync: Sync

    static let `default` = DaemonSettings(
        version: currentVersion,
        retention: Retention(maximumItems: 500, maximumAgeDays: 30),
        sync: Sync(enabled: true)
    )

    private static let secondsPerDay: TimeInterval = 24 * 60 * 60

    /// The store's policy, with 0 turned back into "no limit".
    var retentionPolicy: RetentionPolicy {
        RetentionPolicy(
            maximumItems: retention.maximumItems == 0 ? nil : retention.maximumItems,
            maximumAge: retention.maximumAgeDays == 0
                ? nil : TimeInterval(retention.maximumAgeDays) * Self.secondsPerDay
        )
    }

    /// These settings with what `patch` names changed, and stamped with the
    /// version this build writes. Does not validate — ``SettingsPatch/refusal``
    /// is checked before this is called.
    func applying(_ patch: SettingsPatch) -> DaemonSettings {
        DaemonSettings(
            version: Self.currentVersion,
            retention: Retention(
                maximumItems: patch.maximumItems ?? retention.maximumItems,
                maximumAgeDays: patch.maximumAgeDays ?? retention.maximumAgeDays
            ),
            sync: Sync(enabled: patch.syncEnabled ?? sync.enabled)
        )
    }

    /// Why a file holding these settings cannot be trusted, or nil.
    ///
    /// A value the daemon would have refused over the bus is refused from the
    /// file too — a hand edit to `-1` must not become a cap nobody can read.
    var problem: String? {
        guard version >= 1 else { return "version \(version) is not a settings version" }
        return SettingsPatch(
            maximumItems: retention.maximumItems,
            maximumAgeDays: retention.maximumAgeDays
        ).refusal
    }
}

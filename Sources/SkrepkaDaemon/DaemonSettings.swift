import Foundation
import SkrepkaCore
import SkrepkaIPC
import SkrepkaSync

/// What `config.json` holds: the settings a user changes, and nothing the
/// daemon works out for itself.
///
/// ```json
/// {"version":1,"retention":{"maximumItems":500,"maximumAgeDays":30},"sync":{"enabled":true},
///  "fileSync":{"maximumBytes":33554432},"paste":{"automatic":true}}
/// ```
///
/// Limits use 0 for "no limit", as ``SkrepkaIPC/SettingsDocument`` does, so a
/// stored "unlimited" is a choice rather than an absent key that reads back as
/// the default — except the file-size limit, where 0 stops file contents
/// syncing, because a bundle has no "no limit" to stand for. The defaults are
/// exactly what the daemon did before the file existed — 500 entries, 30 days,
/// sync on, files up to the ceiling — so a machine with no file behaves as it
/// always has.
///
/// `fileSync` and `paste` arrived after the format did, so a file without them
/// reads them as their defaults rather than being set aside as unusable.
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

    struct FileSync: Codable, Sendable, Hashable {
        let maximumBytes: Int
    }

    struct Paste: Codable, Sendable, Hashable {
        let automatic: Bool
    }

    let version: Int
    let retention: Retention
    let sync: Sync
    let fileSync: FileSync
    let paste: Paste

    static let `default` = DaemonSettings(
        version: currentVersion,
        retention: Retention(maximumItems: 500, maximumAgeDays: 30),
        sync: Sync(enabled: true)
    )

    init(
        version: Int,
        retention: Retention,
        sync: Sync,
        fileSync: FileSync = FileSync(maximumBytes: FileSyncLimit.defaultBytes),
        paste: Paste = Paste(automatic: SettingsDocument.Paste.default.isAutomatic)
    ) {
        self.version = version
        self.retention = retention
        self.sync = sync
        self.fileSync = fileSync
        self.paste = paste
    }

    private enum CodingKeys: String, CodingKey {
        case version, retention, sync, fileSync, paste
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        retention = try container.decode(Retention.self, forKey: .retention)
        sync = try container.decode(Sync.self, forKey: .sync)
        fileSync = try container.decodeIfPresent(FileSync.self, forKey: .fileSync) ?? Self.default.fileSync
        paste = try container.decodeIfPresent(Paste.self, forKey: .paste) ?? Self.default.paste
    }

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
            sync: Sync(enabled: patch.syncEnabled ?? sync.enabled),
            fileSync: FileSync(maximumBytes: patch.maximumFileSyncBytes ?? fileSync.maximumBytes),
            paste: Paste(automatic: patch.pasteAutomatically ?? paste.automatic)
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
            maximumAgeDays: retention.maximumAgeDays,
            maximumFileSyncBytes: fileSync.maximumBytes
        ).refusal
    }
}

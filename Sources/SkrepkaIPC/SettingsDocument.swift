import Foundation

/// The daemon's settings, as ``SkrepkaInterface/Member/settings`` answers them:
/// what the Settings window's History and Sync panes draw, and what
/// `skrepka config` prints. Since interface version 4.
///
/// Limits use 0 for "no limit", the macOS `Preferences` convention: a stored 0
/// is a choice the user made, where an absent value would read back as the
/// default and silently undo it.
public struct SettingsDocument: SkrepkaDocument, Hashable {
    /// How much history is kept. Pinned entries are never evicted.
    public struct Retention: Codable, Sendable, Hashable {
        /// The most unpinned entries kept; 0 for no limit.
        public let maximumItems: Int
        /// The oldest an unpinned entry may get, in days; 0 for no limit.
        public let maximumAgeDays: Int

        public init(maximumItems: Int, maximumAgeDays: Int) {
            self.maximumItems = maximumItems
            self.maximumAgeDays = maximumAgeDays
        }

        /// The choices a client offers, in order — the macOS History pane's,
        /// with 0 standing for its "Unlimited" and "Never".
        public static let itemChoices = [100, 250, 500, 1000, 5000, 0]
        public static let ageChoices = [1, 7, 30, 90, 365, 0]
    }

    /// Whether this device shares history with paired devices.
    public struct Sync: Codable, Sendable, Hashable {
        public let isEnabled: Bool
        /// True when the daemon was started with `--no-sync`, which no setting
        /// overrides — a client shows the switch off and disabled, and says
        /// why.
        public let isLockedOff: Bool

        public init(isEnabled: Bool, isLockedOff: Bool) {
            self.isEnabled = isEnabled
            self.isLockedOff = isLockedOff
        }
    }

    /// What the history holds now, for the History pane's figures.
    public struct HistoryCounts: Codable, Sendable, Hashable {
        public let entries: Int
        public let pinned: Int
        public let images: Int

        public init(entries: Int, pinned: Int, images: Int) {
            self.entries = entries
            self.pinned = pinned
            self.images = images
        }
    }

    public let version: UInt32
    public let retention: Retention
    public let sync: Sync
    public let history: HistoryCounts
    /// The clipboard markers that keep a copy out of history, each as the
    /// MIME type and value a person could look up — what the Privacy pane
    /// lists under "always protected".
    public let protectedMarkers: [String]

    /// How large a copy of files may be and still sync its contents. Since
    /// interface version 5; a document from an older daemon reads as
    /// ``FileSync/default``.
    public let fileSync: FileSync

    /// Whether choosing an entry in the picker pastes it. Since interface
    /// version 5; a document from an older daemon reads as ``Paste/default``.
    public let paste: Paste

    public init(
        retention: Retention,
        sync: Sync,
        history: HistoryCounts,
        protectedMarkers: [String],
        fileSync: FileSync = .default,
        paste: Paste = .default,
        version: UInt32 = SkrepkaInterface.version
    ) {
        self.version = version
        self.retention = retention
        self.sync = sync
        self.history = history
        self.protectedMarkers = protectedMarkers
        self.fileSync = fileSync
        self.paste = paste
    }

    private enum CodingKeys: String, CodingKey {
        case version, retention, sync, history, protectedMarkers, fileSync, paste
    }

    /// Tolerates a document without the version-5 members, so a client
    /// updated before the daemon it talks to still reads the settings rather
    /// than calling the whole answer malformed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(UInt32.self, forKey: .version)
        retention = try container.decode(Retention.self, forKey: .retention)
        sync = try container.decode(Sync.self, forKey: .sync)
        history = try container.decode(HistoryCounts.self, forKey: .history)
        protectedMarkers = try container.decode([String].self, forKey: .protectedMarkers)
        fileSync = try container.decodeIfPresent(FileSync.self, forKey: .fileSync) ?? .default
        paste = try container.decodeIfPresent(Paste.self, forKey: .paste) ?? .default
    }
}

// MARK: - Version 5

extension SettingsDocument {
    /// How large a copy of files may be and still have its contents synced.
    public struct FileSync: Codable, Sendable, Hashable {
        /// The largest limit there is, in bytes: the protocol's payload ceiling.
        ///
        /// Restated from `SkrepkaSync.FileSyncLimit.ceiling`, because this
        /// target is the CLI's and links nothing but D-Bus. The daemon's tests
        /// link both and fail the moment the two disagree.
        public static let ceiling = 32 * 1024 * 1024

        /// What a client offers, smallest first — `FileSyncLimit.choices`,
        /// restated and checked the same way. 0 is "don't sync file contents".
        public static let choices = [0, 1, 5, 10, 20, 32].map { $0 * 1024 * 1024 }

        /// The ceiling, which is what every daemon did before the setting.
        public static let `default` = FileSync(maximumBytes: ceiling)

        /// The largest copy of files whose contents sync, in bytes. 0 means
        /// file contents never sync — the one limit here where 0 is not "no
        /// limit", because the protocol has no such thing for a bundle.
        public let maximumBytes: Int

        public init(maximumBytes: Int) {
            self.maximumBytes = maximumBytes
        }
    }

    /// What choosing an entry in the picker does.
    public struct Paste: Codable, Sendable, Hashable {
        /// On, as on the Mac.
        public static let `default` = Paste(isAutomatic: true)

        /// True when the picker pastes the chosen entry into the window
        /// underneath; false when it only puts it on the clipboard.
        public let isAutomatic: Bool

        public init(isAutomatic: Bool) {
            self.isAutomatic = isAutomatic
        }
    }
}

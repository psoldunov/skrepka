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

    public init(
        retention: Retention,
        sync: Sync,
        history: HistoryCounts,
        protectedMarkers: [String],
        version: UInt32 = SkrepkaInterface.version
    ) {
        self.version = version
        self.retention = retention
        self.sync = sync
        self.history = history
        self.protectedMarkers = protectedMarkers
    }
}

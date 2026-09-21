import Foundation

/// A change to some of the daemon's settings: what
/// ``SkrepkaInterface/Member/setSettings`` takes. Since interface version 4.
///
/// Every field is optional and nil leaves that setting alone, so a client
/// changes one thing without reading and re-sending the rest — two windows
/// flipping different switches cannot undo each other — and a setting added
/// later needs a field here rather than a new member.
///
/// Limits use 0 for "no limit", as ``SettingsDocument`` does. The daemon
/// refuses a negative limit, and a limit past ``maximumItemsLimit`` or
/// ``maximumAgeDaysLimit``, with an `ok: false` ``ActionDocument`` saying so.
public struct SettingsPatch: SkrepkaDocument, Hashable {
    /// The largest item limit the daemon accepts.
    public static let maximumItemsLimit = 1_000_000
    /// The largest age limit the daemon accepts, in days — a hundred years.
    public static let maximumAgeDaysLimit = 36_500

    public let version: UInt32
    public var maximumItems: Int?
    public var maximumAgeDays: Int?
    // swiftlint:disable:next discouraged_optional_boolean
    public var syncEnabled: Bool?  // Three states on purpose: nil leaves sync alone.

    public init(
        maximumItems: Int? = nil,
        maximumAgeDays: Int? = nil,
        // swiftlint:disable:next discouraged_optional_boolean
        syncEnabled: Bool? = nil,  // Nil means "no change", as for every field here.
        version: UInt32 = SkrepkaInterface.version
    ) {
        self.version = version
        self.maximumItems = maximumItems
        self.maximumAgeDays = maximumAgeDays
        self.syncEnabled = syncEnabled
    }

    /// Whether the patch changes nothing at all.
    public var isEmpty: Bool {
        maximumItems == nil && maximumAgeDays == nil && syncEnabled == nil
    }
}

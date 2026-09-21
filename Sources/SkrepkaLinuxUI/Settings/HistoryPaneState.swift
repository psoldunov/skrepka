import Foundation
import SkrepkaIPC

/// The History pane, as the widgets draw it: the three figures, the two
/// retention choices and Clear….
public struct HistoryPaneState: Sendable, Hashable {
    /// One drop-down: its labels, which is chosen, and the value behind each.
    public struct Choice: Sendable, Hashable {
        public let labels: [String]
        public let values: [Int]
        public let selected: Int
    }

    public let banner: SyncPaneState.Banner?
    /// Entries, pinned and images, as text — "—" until the daemon has
    /// answered.
    public let entries: String
    public let pinned: String
    public let images: String
    public let keepAtMost: Choice
    public let discardAfter: Choice
    public let isEditable: Bool
    public let isClearEnabled: Bool
    public let clearTitle: String

    public init(_ model: PreferencesModel) {
        let document = model.document
        let retention = document?.retention
        banner = PreferencesBanner.banner(model)
        entries = Self.count(document?.history.entries)
        pinned = Self.count(document?.history.pinned)
        images = Self.count(document?.history.images)
        let items = model.inFlight.last { $0.maximumItems != nil }?.maximumItems ?? retention?.maximumItems
        let days =
            model.inFlight.last { $0.maximumAgeDays != nil }?.maximumAgeDays ?? retention?.maximumAgeDays
        keepAtMost =
            items.map {
                Self.choice(SettingsDocument.Retention.itemChoices, current: $0, label: Self.itemLabel)
            } ?? Self.unknown
        discardAfter =
            days.map {
                Self.choice(SettingsDocument.Retention.ageChoices, current: $0, label: Self.ageLabel)
            } ?? Self.unknown
        isEditable = model.isEditable
        isClearEnabled = model.isEditable && !model.isClearing
        clearTitle = model.isClearing ? "Clearing…" : "Clear…"
    }

    /// The offered values, with the current one slotted in where it belongs
    /// when it is not among them — `skrepka config` can set any limit, and a
    /// drop-down that cannot show the value in force would silently offer to
    /// change it. Unlimited stays last.
    static func choice(_ offered: [Int], current: Int, label: (Int) -> String) -> Choice {
        var limited = offered.filter { $0 > 0 }
        if current > 0, !limited.contains(current) {
            limited = (limited + [current]).sorted()
        }
        let values = limited + [0]
        let selected = values.firstIndex(of: current) ?? values.count - 1
        return Choice(labels: values.map(label), values: values, selected: selected)
    }

    /// A drop-down with nothing to offer yet: the daemon has not said what
    /// the limit is, and guessing "Unlimited" would misstate it.
    static let unknown = Choice(labels: ["—"], values: [], selected: 0)

    static func itemLabel(_ items: Int) -> String {
        items == 0 ? "Unlimited" : "\(items) items"
    }

    static func ageLabel(_ days: Int) -> String {
        switch days {
        case 0: "Never"
        case 1: "1 day"
        case 365: "1 year"
        default: "\(days) days"
        }
    }

    private static func count(_ value: Int?) -> String {
        guard let value else { return "—" }
        return value.formatted()
    }
}

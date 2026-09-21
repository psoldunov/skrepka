import Foundation

/// "10 seconds ago", "3 minutes ago" — the relative age a picker row shows
/// under its title.
///
/// The macOS row uses `Date.formatted(.relative(presentation: .numeric))`,
/// which reads the system locale. This is its Linux counterpart, spelled out
/// rather than borrowed for two reasons: it is deterministic, so the subtitle
/// assembly in ``PickerRowTextBuilder`` can be tested against exact strings
/// without pinning a locale, and it reads the same on the Steam Deck whatever
/// the desktop's locale, which is what keeps the port looking like the Mac.
///
/// Numeric presentation only — "1 minute ago", never "a minute ago" — matching
/// the `.numeric` the macOS picker asks for.
public enum RelativeTime {
    /// One unit and its threshold, largest first. The first whose span the age
    /// meets or exceeds names the row's age.
    private struct Unit {
        let seconds: Double
        let singular: String
        let plural: String
    }

    private static let units: [Unit] = [
        Unit(seconds: 31_536_000, singular: "year", plural: "years"),
        Unit(seconds: 2_592_000, singular: "month", plural: "months"),
        Unit(seconds: 604_800, singular: "week", plural: "weeks"),
        Unit(seconds: 86_400, singular: "day", plural: "days"),
        Unit(seconds: 3_600, singular: "hour", plural: "hours"),
        Unit(seconds: 60, singular: "minute", plural: "minutes"),
        Unit(seconds: 1, singular: "second", plural: "seconds"),
    ]

    /// The age of `date` as of `now`, in words.
    ///
    /// A future date reads "in N units"; anything under a second, past or
    /// future, reads "now", so a row captured this instant does not flicker
    /// between "in 0 seconds" and "0 seconds ago".
    public static func string(from date: Date, to now: Date) -> String {
        let interval = now.timeIntervalSince(date)
        let magnitude = abs(interval)
        guard magnitude >= 1 else { return "now" }
        let unit = units.first { magnitude >= $0.seconds } ?? units[units.count - 1]
        let count = Int((magnitude / unit.seconds).rounded(.down))
        let noun = count == 1 ? unit.singular : unit.plural
        return interval >= 0 ? "\(count) \(noun) ago" : "in \(count) \(noun)"
    }
}

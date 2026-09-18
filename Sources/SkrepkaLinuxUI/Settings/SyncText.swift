import Foundation

/// The few pieces of wording the Settings window builds rather than states.
enum SyncText {
    /// Capitalised, and ending in a full stop unless it already ends a
    /// sentence.
    ///
    /// The daemon's `ActionDocument` details are lower-case fragments —
    /// "forgot MacBook", "asked 1 peer to sync" — because the CLI prints them
    /// after its own prefix. A window shows them on their own.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "" }
        let capitalised = first.uppercased() + trimmed.dropFirst()
        guard let last = capitalised.last, !".!?…".contains(last) else { return capitalised }
        return capitalised + "."
    }

    /// How long ago something happened, to the minute.
    ///
    /// Coarse on purpose: the list redraws when this string changes, and a
    /// row counting seconds would rebuild the whole list every poll.
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600:
            let minutes = seconds / 60
            return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
        case ..<86_400:
            let hours = seconds / 3600
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        default: return "more than a day ago"
        }
    }

    /// A wall-clock time, `14:05`, in `timeZone`.
    static func clock(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        return String(format: "%02d:%02d", hour, minute)
    }

    /// What a platform string from the daemon is called on screen.
    static func platform(_ name: String) -> String {
        switch name {
        case "macos": "Mac"
        case "linux": "Linux"
        default: "Unknown system"
        }
    }
}

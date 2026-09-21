import Foundation

// MARK: - Validation

extension SettingsPatch {
    /// Why the daemon would refuse this patch, in a sentence for a person, or
    /// nil when every limit it names is in range.
    ///
    /// Here rather than in the daemon alone so a client can check before it
    /// sends — `skrepka config set` says "you typed it wrong" with exit code 2
    /// rather than a round trip — while the daemon, which checks again, stays
    /// the authority. One rule in one place means the two cannot disagree about
    /// what "in range" is.
    public var refusal: String? {
        if let maximumItems, let reason = Self.refusal(maximumItems, limit: Self.maximumItemsLimit) {
            return "the item limit \(reason)"
        }
        if let maximumAgeDays, let reason = Self.refusal(maximumAgeDays, limit: Self.maximumAgeDaysLimit) {
            return "the age limit \(reason)"
        }
        return nil
    }

    private static func refusal(_ value: Int, limit: Int) -> String? {
        if value < 0 { return "cannot be negative — use 0 for no limit" }
        if value > limit { return "can be at most \(limit) — use 0 for no limit" }
        return nil
    }
}

import Foundation

/// How many rebuilds in a row one half of the avahi backend may attempt before
/// that half is left alone.
///
/// **One budget per half — the browse and the advertisement — and each is reset
/// only by its own success.** A single shared counter does not work, and the
/// reason is the order ``AvahiDiscovery`` rebuilds in: the browse goes first and
/// reports success the moment avahi hands out a `ServiceBrowser`, which is
/// before the republish has been attempted at all. A daemon that comes up far
/// enough to answer `ServiceBrowserNew` and then dies again therefore refilled
/// the budget on every cycle, so the bound never engaged and the daemon
/// republished on every iteration of a crash-loop — the storm the bound exists
/// to stop.
///
/// A browser arriving is the browse's own end-to-end success: nothing later
/// confirms a browse, so ``recordWorking()`` on that half is right where it is.
/// What it must not do is vouch for the other half, which costs an entry group,
/// up to ``AvahiDiscovery/nameAttempts`` commits and a registration wait each
/// time.
struct RecoveryBudget: Sendable {
    /// How many consecutive rebuilds are worth trying.
    ///
    /// A daemon crash-looping emits `RUNNING` every few seconds, and chasing it
    /// for ever would rebuild on every cycle. Counting *consecutive* failures
    /// bounds a storm without capping the lifetime total: a machine whose avahi
    /// restarts once a week recovers every week.
    static let limit = 5

    /// Rebuilds attempted since this half was last in a working state.
    private(set) var attempts = 0

    /// Whether the budget is spent, and the rebuild has to be skipped.
    var isExhausted: Bool { attempts >= Self.limit }

    /// Spends one attempt, and says whether there was one to spend.
    mutating func spend() -> Bool {
        guard !isExhausted else { return false }
        attempts += 1
        return true
    }

    /// Notes that this half reached a working state, so the next restart gets
    /// the full budget again.
    mutating func recordWorking() {
        attempts = 0
    }
}

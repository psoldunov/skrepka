/// When the app asks the daemon again after a check failed.
///
/// A failed check used to stand for the life of the app: the tray said the
/// background service was not running until somebody chose that row, and at
/// login — where the app and the daemon start together, and the app's first
/// check can land before the daemon answers — that meant quitting and
/// relaunching the app. So a failed check schedules the next one, quickly at
/// first, because the usual cause is a daemon still coming up, and then every
/// half minute for as long as it takes.
enum DaemonRecheck {
    /// Seconds to the next check, by how many have failed in a row. The last
    /// entry repeats.
    static let delays: [UInt32] = [2, 5, 10, 30]

    /// The wait after `failures` checks in a row have failed. Anything below
    /// one is read as one.
    static func delay(afterFailures failures: Int) -> UInt32 {
        delays[min(max(failures, 1), delays.count) - 1]
    }
}

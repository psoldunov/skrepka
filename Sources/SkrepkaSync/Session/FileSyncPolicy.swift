import Foundation

/// The file-size limit sync consults while it runs — see ``FileSyncLimit`` for
/// what the number means and the three places it is applied.
///
/// An actor rather than a value on ``SyncRuntime``: the runtime is built once,
/// when sync starts, and the user changes this limit while links are up. Every
/// exchange, responder and push reads the current answer at the moment it needs
/// one, so a lower limit takes effect on the next offer rather than on the next
/// restart.
///
/// Built once by whoever owns the setting and handed to every runtime it
/// builds, so a sync restart does not reset it to the default.
public actor FileSyncPolicy {
    /// The limit now, already inside `0...FileSyncLimit.ceiling`.
    public private(set) var maximumBytes: Int

    public init(maximumBytes: Int = FileSyncLimit.defaultBytes) {
        self.maximumBytes = FileSyncLimit.clamped(maximumBytes)
    }

    /// Changes the limit. Out-of-range values are clamped rather than refused:
    /// the settings surfaces validate before they get here, and a policy that
    /// could hold a negative limit would be one more thing every reader checks.
    public func setMaximumBytes(_ bytes: Int) {
        maximumBytes = FileSyncLimit.clamped(bytes)
    }
}

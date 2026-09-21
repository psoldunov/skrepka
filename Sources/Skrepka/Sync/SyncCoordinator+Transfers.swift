import SkrepkaCore
import SkrepkaSync

// The file-size limit and the progress of what peers are sending: the two
// things sync reads from and reports to while links are up, rather than at
// bring-up. Both outlive a restart — see `SyncRuntime.fileSync` and
// `SyncRuntime.transfers`.
extension SyncCoordinator {
    /// Changes the file-size limit, for the setting in the Sync pane.
    ///
    /// Saved at once and handed to sync through a chain rather than a `Task`
    /// per change, so two quick picks reach the policy in the order they were
    /// made.
    func setFileSyncLimit(_ bytes: Int) {
        preferences.maximumFileSyncBytes = bytes
        let limit = preferences.maximumFileSyncBytes
        let previous = fileLimitTail
        fileLimitTail = Task { [fileSync] in
            await previous?.value
            await fileSync.setMaximumBytes(limit)
        }
    }

    /// Follows the transfer monitor for the life of the coordinator, turning
    /// each snapshot into per-row fractions the picker draws.
    func watchTransfers() {
        transferTask?.cancel()
        transferTask = Task { [weak self, transfers] in
            for await snapshot in await transfers.updates() {
                guard let self else { return }
                transferProgress.apply(snapshot) { store.entryID(forContentHash: $0) }
            }
        }
    }
}

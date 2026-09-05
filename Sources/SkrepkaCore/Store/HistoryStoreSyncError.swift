import Foundation

/// What the store's sync surface refuses to do.
public enum HistoryStoreSyncError: Error, Equatable {
    /// ``HistoryStore/localDeviceID`` has not been set.
    ///
    /// Every offer a peer receives names the device that made it, and a
    /// `SyncDeviceID` is derived from this machine's certificate — it cannot be
    /// invented here. A store with no identity has nothing truthful to say, so
    /// it says nothing rather than describing itself as some other device.
    case deviceIdentityUnavailable
}

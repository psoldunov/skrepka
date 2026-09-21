import Foundation

// MARK: - What a picker row says about it

extension SyncedFilesStatus {
    /// The words a row's subtitle adds, or nil when there is nothing to warn
    /// about. Lower case: it sits mid-line, between the type and the time.
    ///
    /// A row whose files did not come pastes their names rather than the files,
    /// and saying so on the row is what keeps that from being a surprise.
    public var rowNote: String? {
        switch self {
        case .synced: nil
        case .pending: "contents not synced yet"
        case .notSynced: "contents not synced"
        }
    }
}

import Foundation
import SkrepkaSync

/// Whether a file row from another device carries the files themselves — what
/// a row shows so "pastes as names" is never a surprise.
public enum SyncedFilesStatus: Sendable, Hashable {
    /// The files arrived and paste as files.
    case synced
    /// The sender attached the files and their bytes have not arrived yet.
    case pending
    /// No files came — a folder, a copy over ``FileBundleReader/limit``, or a
    /// sender too old to attach them. The row pastes as the files' names.
    case notSynced

    /// The status of one row, or nil for a row it does not apply to: anything
    /// but a file row, and any row this device recorded itself.
    ///
    /// - Parameters:
    ///   - offeredTypes: every type the row's representation index lists,
    ///     held or not.
    ///   - heldTypes: the types whose bytes this device holds.
    public static func of(
        kind: ClipKind,
        isForeign: Bool,
        offeredTypes: Set<String>,
        heldTypes: Set<String>
    ) -> SyncedFilesStatus? {
        guard isForeign, kind.isFileSystemEntry else { return nil }
        if heldTypes.contains(FileBundle.storageType) { return .synced }
        return offeredTypes.contains(FileBundle.storageType) ? .pending : .notSynced
    }
}

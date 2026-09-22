import Foundation
import SkrepkaSync

/// Whether a file row from another device carries the files themselves — what
/// a row shows so "pastes as names" is never a surprise.
public enum SyncedFilesStatus: Sendable, Hashable {
    /// The files arrived and paste as files.
    case synced
    /// The sender attached the files and their bytes have not arrived yet.
    case pending
    /// No files came — a folder, a copy over the sender's file-size limit, or
    /// a sender too old to attach them. The row pastes as the files' names.
    case notSynced
    /// The sender attached the files, and they are larger than this device's
    /// own file-size limit, so they are not fetched — see
    /// `SkrepkaSync.FileSyncLimit`. The row pastes as the files' names until
    /// the limit is raised, when the bytes arrive on the next exchange.
    case overLimit

    /// The status of one row, or nil for a row it does not apply to: anything
    /// but a file row, and any row this device recorded itself.
    ///
    /// - Parameters:
    ///   - offeredTypes: every type the row's representation index lists,
    ///     held or not.
    ///   - heldTypes: the types whose bytes this device holds.
    ///   - offeredBundleBytes: the size the sender gave its bundle, when the
    ///     index records one.
    ///   - fileLimit: this device's file-size limit. The ceiling by default,
    ///     which is what every build before the setting fetched.
    public static func of(
        kind: ClipKind,
        isForeign: Bool,
        offeredTypes: Set<String>,
        heldTypes: Set<String>,
        offeredBundleBytes: Int? = nil,
        fileLimit: Int = FileSyncLimit.ceiling
    ) -> SyncedFilesStatus? {
        guard isForeign, kind.isFileSystemEntry else { return nil }
        if heldTypes.contains(FileBundle.storageType) { return .synced }
        guard offeredTypes.contains(FileBundle.storageType) else { return .notSynced }
        if let offeredBundleBytes, !FileSyncLimit.admits(offeredBundleBytes, under: fileLimit) {
            return .overLimit
        }
        return .pending
    }

    /// Whether the answer can change without the row itself changing — a row
    /// waiting for bytes, or one waiting for the limit to be raised. The Mac's
    /// picker keeps every other answer rather than asking the store again.
    public var canChange: Bool {
        self == .pending || self == .overLimit
    }
}

import SkrepkaCore
import SkrepkaIPC

/// The Sync pane's "Sync files up to" drop-down: the limits offered, the one in
/// force, and whether it can be changed from here.
public struct FileLimitState: Sendable, Hashable {
    public let choice: HistoryPaneState.Choice
    public let isEnabled: Bool

    /// As the daemon says — or as the user last put it while that change is on
    /// its way. A limit set with `skrepka config` that is not one of the
    /// choices is slotted in among them, for ``HistoryPaneState``'s reason: a
    /// drop-down that cannot show the value in force would silently offer to
    /// change it.
    public init(_ model: PreferencesModel) {
        guard let document = model.document else {
            choice = HistoryPaneState.unknown
            isEnabled = false
            return
        }
        let wanted = model.inFlight.last { $0.maximumFileSyncBytes != nil }?.maximumFileSyncBytes
        let current = wanted ?? document.fileSync.maximumBytes
        let values = FileSyncLimitLabel.choices(including: current)
        choice = HistoryPaneState.Choice(
            labels: values.map(FileSyncLimitLabel.text(for:)),
            values: values,
            selected: values.firstIndex(of: current) ?? values.count - 1
        )
        // Not tied to the sharing switch: the limit also decides what a copy
        // keeps of its files here, so it stays settable with sharing off. Tied
        // to the daemon's version: one older than 5 reads a document without
        // the limit as the default, and would ignore a change to it.
        isEnabled = model.isEditable && document.version >= Self.minimumDaemonVersion
    }

    /// The first interface version whose daemon knows the limit.
    static let minimumDaemonVersion: UInt32 = 5
}

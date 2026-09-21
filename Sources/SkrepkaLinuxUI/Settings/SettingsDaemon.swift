import SkrepkaIPC

/// Every daemon member the Settings window calls: the Sync pane's, plus the
/// ones behind General, History and Diagnostics.
///
/// A protocol for the reason ``SyncDaemon`` is one — the window is tested,
/// and its demo is drawn, against a fake.
public protocol SettingsDaemon: SyncDaemon {
    /// The interface version the daemon exports. Below 4 it has no
    /// `Settings`/`SetSettings`, and the window says to update it rather
    /// than calling members that are not there.
    func interfaceVersion() async throws -> UInt32
    func settings() async throws -> SettingsDocument
    func setSettings(_ patch: SettingsPatch) async throws -> ActionDocument
    func clear(keepingPinned: Bool) async throws -> ActionDocument
    func diagnostics() async throws -> DiagnosticsDocument
}

extension DaemonProxy: SettingsDaemon {}

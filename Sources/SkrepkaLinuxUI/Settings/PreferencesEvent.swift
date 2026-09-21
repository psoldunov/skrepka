import SkrepkaIPC

/// What the daemon said to one of the General, History, Privacy or
/// Diagnostics panes' calls — the counterpart of ``SyncEvent`` for everything
/// that is not pairing.
public enum PreferencesEvent: Sendable, Equatable {
    /// What reading the settings found.
    case loaded(PreferencesLoad)
    /// A change the window sent, what the daemon answered, and the settings
    /// read straight afterwards — nil when that read failed, in which case the
    /// window keeps what it had.
    case changed(SettingsPatch, Result<ActionDocument, SyncFailure>, refreshed: SettingsDocument?)
    /// Clear History's answer, and the settings read straight afterwards for
    /// the new counts.
    case cleared(Result<ActionDocument, SyncFailure>, refreshed: SettingsDocument?)
    case diagnosed(Result<DiagnosticsDocument, SyncFailure>)
}

/// The outcome of reading the settings.
public enum PreferencesLoad: Sendable, Equatable {
    case ready(SettingsDocument)
    /// The daemon answers, but predates `Settings`: it exports this interface
    /// version, below ``PreferencesModel/requiredVersion``.
    case unsupported(UInt32)
    case failed(SyncFailure)
}

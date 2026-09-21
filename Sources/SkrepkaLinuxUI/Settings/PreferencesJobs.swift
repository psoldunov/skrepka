import SkrepkaIPC

/// The General, History, Privacy and Diagnostics panes' calls to the daemon,
/// each run to an event.
///
/// They run as ``DaemonLink`` jobs, in the one queue the Sync pane's calls
/// use, so none can time out behind a pairing dial and take the bus session
/// down with it.
enum PreferencesJobs {
    typealias Connect = @Sendable () async throws -> any SettingsDaemon

    /// The settings, or why there are none: a daemon older than version 4
    /// is asked nothing it cannot answer.
    static func load(_ connect: Connect) async -> PreferencesEvent {
        do {
            let daemon = try await connect()
            let version = try await daemon.interfaceVersion()
            guard version >= PreferencesModel.requiredVersion else { return .loaded(.unsupported(version)) }
            return .loaded(.ready(try await daemon.settings()))
        } catch {
            return .loaded(.failed(SyncFailure(describing: error)))
        }
    }

    static func change(_ patch: SettingsPatch, _ connect: Connect) async -> PreferencesEvent {
        let daemon: any SettingsDaemon
        do {
            daemon = try await connect()
        } catch {
            return .changed(patch, .failure(SyncFailure(describing: error)), refreshed: nil)
        }
        let result = await answer { try await daemon.setSettings(patch) }
        return .changed(patch, result, refreshed: await refreshed(daemon))
    }

    static func clear(keepingPinned: Bool, _ connect: Connect) async -> PreferencesEvent {
        let daemon: any SettingsDaemon
        do {
            daemon = try await connect()
        } catch {
            return .cleared(.failure(SyncFailure(describing: error)), refreshed: nil)
        }
        let result = await answer { try await daemon.clear(keepingPinned: keepingPinned) }
        return .cleared(result, refreshed: await refreshed(daemon))
    }

    static func diagnose(_ connect: Connect) async -> PreferencesEvent {
        do {
            return .diagnosed(.success(try await connect().diagnostics()))
        } catch {
            return .diagnosed(.failure(SyncFailure(describing: error)))
        }
    }

    private static func answer(
        _ call: () async throws -> ActionDocument
    ) async -> Result<ActionDocument, SyncFailure> {
        do {
            return .success(try await call())
        } catch {
            return .failure(SyncFailure(describing: error))
        }
    }

    /// Discarded deliberately when it fails: the window keeps the settings it
    /// had, and the next load reports the failure itself.
    private static func refreshed(_ daemon: any SettingsDaemon) async -> SettingsDocument? {
        try? await daemon.settings()
    }
}

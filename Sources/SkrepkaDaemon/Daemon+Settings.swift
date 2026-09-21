import Foundation
import Logging
import SkrepkaCore
import SkrepkaIPC

// The `Settings` and `SetSettings` members: retention and the sync switch,
// read and changed while the daemon runs. Since interface version 4.
extension Daemon {
    /// How often an idle daemon re-applies retention, so an age limit ages
    /// entries out of a history nobody is copying into.
    static let retentionSweepInterval: Duration = .seconds(60 * 60)

    /// The settings, the history's figures, and the markers that keep a copy
    /// out of history.
    public func settingsDocument() async -> SettingsDocument {
        SettingsDocument(
            retention: SettingsDocument.Retention(
                maximumItems: settings.retention.maximumItems,
                maximumAgeDays: settings.retention.maximumAgeDays
            ),
            sync: SettingsDocument.Sync(isEnabled: isSyncWanted, isLockedOff: isSyncLockedOff),
            history: await historyCounts(),
            protectedMarkers: Self.protectedMarkers
        )
    }

    /// Changes what `patch` names, saves it, and applies it.
    ///
    /// Queued with bring-up and tear-down: turning sync on or off stops and
    /// starts servers across several awaits, and two windows flipping switches
    /// at once must not interleave their saves.
    public func applySettings(_ patch: SettingsPatch) async -> ActionDocument {
        let answer = enqueueAnswering { await $0.performApplySettings(patch) }
        do {
            return try await answer.value
        } catch {
            // Only thrown when the daemon itself is gone mid-call.
            return .refused("the daemon is shutting down")
        }
    }

    func performApplySettings(_ patch: SettingsPatch) async -> ActionDocument {
        if let refusal = patch.refusal { return .refused(refusal) }
        guard !isStopping else { return .refused("the daemon is shutting down") }
        if patch.syncEnabled == true, isSyncLockedOff {
            return .refused("sync is off for this run: skrepkad was started with --no-sync")
        }
        let previous = settings
        let next = previous.applying(patch)
        do {
            try settingsFile.save(next)
        } catch {
            logger.error(
                "could not save the settings",
                metadata: ["error": .string(String(describing: error))])
            return .refused("could not save the settings: \(error)")
        }
        settings = next
        var problems: [String] = []
        if let problem = await applyRetentionChange(from: previous, to: next) { problems.append(problem) }
        if let problem = await performReconcileSync() { problems.append(problem) }
        guard problems.isEmpty else { return .refused("saved, but " + problems.joined(separator: "; ")) }
        return .succeeded("Saved.")
    }

    /// Hands a changed policy to the store, which applies it at once.
    ///
    /// - Returns: a sentence saying what went wrong, or nil.
    private func applyRetentionChange(
        from previous: DaemonSettings,
        to next: DaemonSettings
    ) async -> String? {
        guard previous.retention != next.retention else { return nil }
        do {
            let evicted = try await store.setRetention(next.retentionPolicy)
            noteEvicted(evicted, reason: "the retention settings changed")
            return nil
        } catch {
            logger.error(
                "could not apply the new retention settings",
                metadata: ["error": .string(String(describing: error))])
            return "the history could not be trimmed now; it will be at the next copy"
        }
    }

    // MARK: - The sweep

    /// Applies retention now and then every ``retentionSweepInterval`` until
    /// ``performStop()`` cancels it.
    ///
    /// Capture is the only other place retention runs, so without this a
    /// 1-day limit on a machine nobody copies on would keep a week-old entry
    /// for as long as nobody copied anything.
    func startRetentionSweep() {
        retentionSweepTask?.cancel()
        retentionSweepTask = Task { [weak self] in
            await self?.sweepRetention()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.retentionSweepInterval)
                } catch {
                    return  // Cancelled: the daemon is stopping.
                }
                await self?.sweepRetention()
            }
        }
    }

    func sweepRetention() async {
        do {
            noteEvicted(try await store.sweepRetention(), reason: "they aged past the retention limit")
        } catch {
            logger.error(
                "could not apply retention",
                metadata: ["error": .string(String(describing: error))])
        }
    }

    private func noteEvicted(_ count: Int, reason: String) {
        guard count > 0 else { return }
        logger.info("evicted \(count) entries: \(reason)")
        notifyHistoryChanged()
    }

    // MARK: - Figures

    private func historyCounts() async -> SettingsDocument.HistoryCounts {
        do {
            let counts = try await store.counts()
            return SettingsDocument.HistoryCounts(
                entries: counts.entries, pinned: counts.pinned, images: counts.pictures)
        } catch {
            logger.error(
                "could not count the history",
                metadata: ["error": .string(String(describing: error))])
            return SettingsDocument.HistoryCounts(entries: 0, pinned: 0, images: 0)
        }
    }

    /// The markers the capture path refuses to record, as a person could look
    /// them up: the KDE hint with the one value that counts, then the
    /// nspasteboard.org family by name.
    static let protectedMarkers: [String] = {
        let kde = PrivacyMarkers.kdePasswordManagerHint
        let others = PrivacyMarkers.rejected.subtracting([kde]).sorted()
        return ["\(kde) = \(PrivacyMarkers.kdePasswordManagerHintSecret)"] + others
    }()
}

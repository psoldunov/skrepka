import Foundation
import SkrepkaIPC

/// Everything the General, History, Privacy and Diagnostics panes know about
/// the daemon, and the Sync pane's sharing switch: the settings, what is on
/// its way to changing them, and the last thing worth telling the user.
///
/// A value, like ``SyncModel``: each method answers a new model, and nothing
/// here touches GTK or the bus, so every decision is testable.
public struct PreferencesModel: Sendable, Equatable {
    /// The first interface version with `Settings` and `SetSettings`.
    public static let requiredVersion: UInt32 = 4

    public enum Availability: Sendable, Equatable {
        case loading
        case ready(SettingsDocument)
        case unsupported(UInt32)
        case unreachable(SyncFailure)
    }

    public enum Diagnosis: Sendable, Equatable {
        case loading
        case ready(DiagnosticsDocument)
        case failed(SyncFailure)
    }

    public let availability: Availability
    public let diagnosis: Diagnosis
    /// Changes sent and not yet answered, oldest first. A control shows the
    /// newest one that touches it, so a switch flipped twice in quick
    /// succession does not bounce back while the first answer arrives.
    public let inFlight: [SettingsPatch]
    public let isClearing: Bool
    public let notice: SyncNotice?

    public init(
        availability: Availability = .loading,
        diagnosis: Diagnosis = .loading,
        inFlight: [SettingsPatch] = [],
        isClearing: Bool = false,
        notice: SyncNotice? = nil
    ) {
        self.availability = availability
        self.diagnosis = diagnosis
        self.inFlight = inFlight
        self.isClearing = isClearing
        self.notice = notice
    }

    /// The settings, once read.
    public var document: SettingsDocument? {
        guard case .ready(let document) = availability else { return nil }
        return document
    }

    /// Whether a control can change anything: the daemon answered, speaks
    /// version 4, and nothing has gone wrong since.
    public var isEditable: Bool { document != nil }

    // MARK: - Out

    public func sending(_ patch: SettingsPatch) -> PreferencesModel {
        with(inFlight: inFlight + [patch])
    }

    public func clearing() -> PreferencesModel {
        withClearing(true)
    }

    public func dismissingNotice() -> PreferencesModel {
        with(notice: .some(nil))
    }

    /// Drops a success notice whose time is up.
    public func expiring(now: Date) -> PreferencesModel {
        guard let clearsAt = notice?.clearsAt, clearsAt <= now else { return self }
        return dismissingNotice()
    }

    // MARK: - In

    public func applying(_ event: PreferencesEvent, now: Date) -> PreferencesModel {
        switch event {
        case .loaded(let load):
            return with(availability: Self.availability(load))
        case .changed(let patch, let result, let refreshed):
            return answered(patch).refreshed(refreshed).with(
                notice: .some(Self.changeNotice(result) ?? notice))
        case .cleared(let result, let refreshed):
            return withClearing(false).refreshed(refreshed).with(
                notice: .some(Self.clearNotice(result, now: now)))
        case .diagnosed(.success(let document)):
            return with(diagnosis: .ready(document))
        case .diagnosed(.failure(let failure)):
            return with(diagnosis: .failed(failure))
        }
    }

    private static func availability(_ load: PreferencesLoad) -> Availability {
        switch load {
        case .ready(let document): .ready(document)
        case .unsupported(let version): .unsupported(version)
        case .failed(let failure): .unreachable(failure)
        }
    }

    private func answered(_ patch: SettingsPatch) -> PreferencesModel {
        guard let index = inFlight.firstIndex(of: patch) else { return self }
        var remaining = inFlight
        remaining.remove(at: index)
        return with(inFlight: remaining)
    }

    private func refreshed(_ document: SettingsDocument?) -> PreferencesModel {
        guard let document else { return self }
        return with(availability: .ready(document))
    }

    /// Nil for a change that went through: the control moving is the answer.
    private static func changeNotice(_ result: Result<ActionDocument, SyncFailure>) -> SyncNotice? {
        switch result {
        case .success(let answer) where answer.ok: nil
        case .success(let answer): .problem(SyncFailure(message: SyncText.sentence(answer.detail)))
        case .failure(let failure): .problem(failure)
        }
    }

    private static func clearNotice(_ result: Result<ActionDocument, SyncFailure>, now: Date) -> SyncNotice {
        switch result {
        case .success(let answer) where answer.ok:
            .success(answer.detail.isEmpty ? "History cleared." : SyncText.sentence(answer.detail), now: now)
        case .success(let answer): .problem(SyncFailure(message: SyncText.sentence(answer.detail)))
        case .failure(let failure): .problem(failure)
        }
    }

    // MARK: - Copies

    private func with(
        availability: Availability? = nil,
        diagnosis: Diagnosis? = nil,
        inFlight: [SettingsPatch]? = nil,
        notice: SyncNotice?? = nil
    ) -> PreferencesModel {
        PreferencesModel(
            availability: availability ?? self.availability,
            diagnosis: diagnosis ?? self.diagnosis,
            inFlight: inFlight ?? self.inFlight,
            isClearing: isClearing,
            notice: notice ?? self.notice
        )
    }

    private func withClearing(_ isClearing: Bool) -> PreferencesModel {
        PreferencesModel(
            availability: availability,
            diagnosis: diagnosis,
            inFlight: inFlight,
            isClearing: isClearing,
            notice: notice)
    }
}

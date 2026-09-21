import Foundation
import Logging
import SkrepkaSync

/// Publishing without avahi, when avahi refuses to.
///
/// avahi answers `org.freedesktop.Avahi.NotPermittedError` in two places, and
/// SteamOS's stock `/etc/avahi/avahi-daemon.conf` trips both: `EntryGroupNew`
/// when `disable-user-service-publishing=yes` (`avahi-daemon/dbus-protocol.c`),
/// and `AddService` when `disable-publishing=yes` (`avahi-core/entry.c`,
/// reached through the entry group). Either way the configuration is root's,
/// and on SteamOS an update puts it back. So instead of asking the user to edit
/// it, skrepkad publishes the one service it needs with ``MDNSAnnouncer`` and
/// leaves avahi browsing and resolving, which it still does.
///
/// **Only then.** Every publish goes to avahi first, including the one after an
/// avahi restart, so a system whose configuration was changed to allow
/// publishing moves back to avahi at the next publish.
extension AvahiDiscovery {
    /// Whether this device is published by ``MDNSAnnouncer`` rather than by
    /// avahi. `skrepka doctor` reports it as information, not as a problem.
    public var isSelfPublishing: Bool { announcer != nil && published != nil }

    /// Whether an error is avahi refusing to publish at all, as opposed to
    /// refusing this one record.
    static func isPublishingRefusal(_ error: any Error) -> Bool {
        guard case .refused(let method, let name, _) = error as? AvahiError else { return false }
        return name == AvahiNames.notPermittedError
            && (method == AvahiNames.Server.entryGroupNew || method == AvahiNames.EntryGroup.addService)
    }

    /// Publishes with skrepkad's own responder, after avahi said no.
    ///
    /// - Parameter refusal: avahi's answer, kept so a responder that cannot
    ///   start either reports both halves — the user needs to know avahi said
    ///   no to know that editing its configuration is the other way out.
    func publishBySelf(_ descriptor: ServiceDescriptor, after refusal: any Error) async throws {
        let announcer = self.announcer ?? MDNSAnnouncer(logger: logger)
        self.announcer = announcer
        let registration: ServiceRegistration
        do {
            registration = try await announcer.start(descriptor)
        } catch {
            self.announcer = nil
            await announcer.stop()
            throw DiscoveryError.advertisingFailed(
                reason:
                    "skrepkad could not publish this device with its own mDNS responder (\(error)). \(describe(refusal))"
            )
        }
        logger.notice(
            "avahi refuses to publish, so skrepkad publishes this device itself",
            metadata: ["name": "\(registration.name)", "avahi": "\(describe(refusal))"])
        published = descriptor
        registrationValue = registration
        recordAdvertisementWorking()
        ensureServerWatch()
        watchSelfPublishing(announcer)
    }

    /// Reports the responder giving up after a conflict, the way a withdrawn
    /// entry group is reported: through ``advertisementFailures()``, which the
    /// daemon turns into "not published" for `skrepka doctor`.
    ///
    /// Held in `entryGroupTask` because it is the same job for the other
    /// publisher, and every teardown already cancels that task.
    private func watchSelfPublishing(_ announcer: MDNSAnnouncer) {
        entryGroupTask?.cancel()
        entryGroupTask = Task { [weak self] in
            for await loss in announcer.losses {
                guard !Task.isCancelled else { return }
                await self?.selfPublishingLost(loss, by: announcer)
                return
            }
        }
    }

    private func selfPublishingLost(_ loss: MDNSAnnouncerError, by announcer: MDNSAnnouncer) {
        // A responder this instance has already replaced is not news.
        guard self.announcer === announcer else { return }
        reportLoss(.advertisingLost(reason: loss.description))
    }

    /// A TXT-only change, re-announced by the responder rather than by avahi.
    func updateBySelf(_ descriptor: ServiceDescriptor, on announcer: MDNSAnnouncer) async throws {
        do {
            registrationValue = try await announcer.update(descriptor)
        } catch {
            throw DiscoveryError.advertisingFailed(reason: "\(error)")
        }
        published = descriptor
    }

    /// Hands back the responder for whoever is stopping it, and forgets it.
    func takeAnnouncer() -> MDNSAnnouncer? {
        defer { announcer = nil }
        return announcer
    }
}

import Foundation
import Logging
import SkrepkaLinuxPlatform

extension Daemon {
    /// Whether capture found no display and can still learn of one.
    ///
    /// False without a user-manager bus to ask, so a daemon built on an empty
    /// environment — a test's — steps over the empty session as it always did.
    var isWaitingForDisplay: Bool {
        userManager != nil && !UserManagerEnvironment.hasDisplay(sessionEnvironment)
    }

    /// Asks the systemd user manager for a display until it has one, then
    /// starts capture as startup would have.
    ///
    /// **This is the Plasma login, not an edge case.** `skrepkad.service` is
    /// wanted by `default.target`, which the user manager reaches before KWin
    /// runs, so the daemon routinely starts with no `WAYLAND_DISPLAY` — and a
    /// process environment is a snapshot that the later export never reaches.
    /// Before this, that daemon captured nothing for the whole session and
    /// said so once, in a journal line nobody reads. See
    /// ``SkrepkaLinuxPlatform/UserManagerEnvironment``.
    ///
    /// It never gives up. A machine with lingering enabled starts the user
    /// manager at boot and the desktop whenever somebody logs in, which may be
    /// hours later; and on a headless machine the whole cost is one property
    /// read every thirty seconds. The delays are ``sessionRetryDelays``, so a
    /// desktop that arrives a few seconds late is caught within seconds.
    func waitForDisplay(attempt: Int) {
        guard !isStopping else { return }
        let delays = Self.sessionRetryDelays
        let delay = delays[min(attempt, delays.count - 1)]
        captureTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                // Cancelled: the daemon is stopping.
                return
            }
            // Queued, like bring-up, and for the reason ``performStart()``
            // gives: this suspends while the manager answers and again while
            // the backend starts, and a `stop()` that landed in either would
            // otherwise finish first and leave a backend nothing will stop.
            await self?.enqueue { await $0.checkForDisplay(attempt: attempt) }.value
        }
    }

    /// Queued work — see ``waitForDisplay(attempt:)``.
    private func checkForDisplay(attempt: Int) async {
        guard !isStopping, let userManager else { return }
        guard let manager = await userManager.read(), UserManagerEnvironment.hasDisplay(manager) else {
            waitForDisplay(attempt: attempt + 1)
            return
        }
        sessionEnvironment = UserManagerEnvironment.filling(sessionEnvironment, from: manager)
        // Done with the manager: the connection is not held open for the
        // life of the daemon just to have answered once.
        await userManager.close()
        // The manager's XAUTHORITY is in a dictionary, where Xlib never looks.
        let hasCookie = XAuthority.adopt(from: sessionEnvironment)
        logger.notice(
            "the desktop exported its display; starting capture",
            metadata: [
                "wayland": .string(sessionEnvironment["WAYLAND_DISPLAY"] ?? "none"),
                "x11": .string(sessionEnvironment["DISPLAY"] ?? "none"),
                "x11-cookie": .string(hasCookie ? "from XAUTHORITY" : "Xlib default"),
            ]
        )
        do {
            try await startClipboard()
        } catch {
            logger.error(
                "the clipboard backend would not start",
                metadata: ["error": .string(String(describing: error))]
            )
            scheduleSessionRestart(attempt: 0)
        }
    }
}

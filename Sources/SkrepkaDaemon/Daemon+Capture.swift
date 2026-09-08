import Foundation
import Logging
import SkrepkaCore
import SkrepkaIPC
import SkrepkaLinuxPlatform
import SkrepkaSync

extension Daemon {
    /// How long to wait before rebuilding a session that went away, by
    /// consecutive attempt.
    ///
    /// A compositor restart, a log out and back in, and a session that is never
    /// coming back all look the same from here — so the delay grows and then
    /// stops growing. The same shape `PeerLink.retryDelays` has, and for the
    /// same reason: a user who logs back in after an hour should be captured
    /// within a minute, not within an hour.
    static var sessionRetryDelays: [Duration] {
        [.seconds(1), .seconds(2), .seconds(5), .seconds(15), .seconds(30)]
    }

    /// What to tell somebody reading the journal when the session offers
    /// nothing to watch.
    ///
    /// The systemd unit deliberately carries no `ExecStartPre` test on
    /// `WAYLAND_DISPLAY` and `DISPLAY` — see `packaging/systemd/skrepkad.service`
    /// for why — so this is where the advice that guard used to give now lives.
    /// One place, and the one that can tell GNOME apart from Weston.
    static func remedy(for report: SessionProbe.Report?) -> String {
        guard let report else { return "run `skrepka doctor` for what this session offers" }
        guard report.waylandDisplay == nil, report.x11Display == nil else {
            return report.problem?.asDiagnosticsProblem?.problem.summary
                ?? "run `skrepka doctor` for what this session offers"
        }
        return """
            Neither WAYLAND_DISPLAY nor DISPLAY is set. If this is a graphical session, the \
            compositor did not export them to the systemd user manager — run \
            `systemctl --user import-environment WAYLAND_DISPLAY DISPLAY XDG_SESSION_TYPE` \
            and restart skrepkad. On a headless machine this is expected, and sync still works.
            """
    }

    /// Starts the clipboard backend and the capture loop over it.
    ///
    /// A session that offers nothing to watch is **reported and stepped over**,
    /// not thrown: GNOME Wayland is exactly that session, and the answer there
    /// is the Shell extension submitting clips over the bus rather than the
    /// daemon refusing to run. `skrepka doctor` is what says so.
    func startClipboard() async throws {
        let probe = SessionProbe().run(environment: environment)
        sessionReport = probe
        do {
            let running = try await ClipboardBackend.start(environment: environment)
            sessionReport = running.report
            clipboard = running
            hasEverCaptured = true
            startCaptureLoop(over: running)
        } catch ClipboardBackend.StartError.unsupportedSession(let report) {
            sessionReport = report
            logger.warning(
                "nothing to watch in this session",
                metadata: [
                    "reason": .string(report.problem?.reportLine ?? "no backend"),
                    "remedy": .string(Self.remedy(for: report)),
                ]
            )
        } catch ClipboardBackend.StartError.backendFailed(let report, let error) {
            sessionReport = report
            logger.error(
                "the clipboard backend would not start",
                metadata: [
                    "backend": .string(report.backend?.displayName ?? "none"),
                    "error": .string(String(describing: error)),
                ]
            )
            scheduleSessionRestart(attempt: 0)
        }
    }

    /// Reads decisions until the backend stops, then rebuilds the session.
    ///
    /// **The rebuild is the phase's ninth "done when".** A `ClipboardSource`
    /// whose session has died stops producing decisions and its stream
    /// finishes; that is the only signal, and it is enough. What happens next
    /// has to be a full rebuild rather than a reconnect, because the compositor
    /// that comes back may not be the one that went away and may not advertise
    /// the same globals — a Wayland session replaced by an X11 one is an
    /// ordinary thing for a user to do. So the probe runs again from scratch.
    private func startCaptureLoop(over running: ClipboardBackend.Running) {
        let watcher = ClipboardWatcher(source: running.source, rules: CaptureRules())
        self.watcher = watcher
        captureTask = Task { [weak self] in
            let decisions = await watcher.start()
            for await decision in decisions {
                guard !Task.isCancelled else { return }
                await self?.record(decision)
            }
            guard !Task.isCancelled else { return }
            await self?.sessionEnded()
        }
    }

    /// The session's stream finished, which means the compositor or the X
    /// server went away.
    func sessionEnded() async {
        guard !isStopping else { return }
        logger.notice("the clipboard session ended; rebuilding")
        await clipboard?.stop()
        clipboard = nil
        watcher = nil
        scheduleSessionRestart(attempt: 0)
    }

    /// Waits, re-probes, and starts whichever backend the session now implies.
    ///
    /// **Whether this ever gives up depends on whether a session has worked
    /// here before, and the difference is the point.**
    ///
    /// A daemon that once had a backend and lost it is watching a compositor
    /// restart — the phase's ninth "done when" is exactly that, and it names
    /// logging out and back in, which comfortably outlasts the whole delay
    /// list. Giving up on it would make the daemon survive a `kwin --replace`
    /// and not a log-out, which is the wrong half. So it keeps retrying at the
    /// last delay, indefinitely: one `SessionProbe` every thirty seconds is an
    /// environment read and at most one connect attempt, which is not spinning.
    ///
    /// A daemon that has *never* had one is on a machine with no display, and
    /// re-probing cannot change that: `SessionProbe` reads the environment this
    /// process was started with, and a `WAYLAND_DISPLAY` exported to the user
    /// manager afterwards is not in it. Only a restart of the unit picks that
    /// up. So this gives up, says so once, and leaves the daemon running for
    /// the sync and the history it can still serve.
    func scheduleSessionRestart(attempt: Int) {
        guard !isStopping else { return }
        let last = Self.sessionRetryDelays.count - 1
        guard attempt <= last || hasEverCaptured else {
            logger.error(
                """
                Gave up rebuilding the clipboard session. Nothing is being captured on this \
                machine; sync and `skrepka list` still work. \(Self.remedy(for: sessionReport))
                """
            )
            return
        }
        let delay = Self.sessionRetryDelays[min(attempt, last)]
        captureTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                // Cancelled: the daemon is stopping and there is nothing to
                // rebuild for.
                return
            }
            await self?.restartSession(attempt: attempt)
        }
    }

    private func restartSession(attempt: Int) async {
        guard !isStopping else { return }
        let probe = SessionProbe().run(environment: environment)
        sessionReport = probe
        guard probe.backend != nil else {
            scheduleSessionRestart(attempt: attempt + 1)
            return
        }
        do {
            let running = try await ClipboardBackend.start(environment: environment)
            sessionReport = running.report
            clipboard = running
            hasEverCaptured = true
            sessionRestarts += 1
            logger.notice(
                "rebuilt the clipboard session",
                metadata: [
                    "backend": .string(running.report.backend?.displayName ?? "none"),
                    "restarts": .stringConvertible(sessionRestarts),
                ]
            )
            startCaptureLoop(over: running)
        } catch {
            scheduleSessionRestart(attempt: attempt + 1)
        }
    }

    // MARK: - One capture

    /// Stores what survived the privacy rules, and offers it to every peer.
    ///
    /// Store first, push after — the same order `AppCoordinator` uses. A push
    /// of something that failed to store would be a peer holding a clip this
    /// device does not.
    func record(_ decision: CaptureDecision) async {
        guard let item = decision.item else {
            if decision.isNoteworthyRejection {
                logger.notice("\(decision.rejectionLogMessage ?? "nothing was captured")")
            }
            return
        }
        guard await store.capture(item) else { return }
        lastCapturedAt = Date()
        notifyHistoryChanged()
        await offerLivePush(item)
    }

    /// Hands what was just copied to every peer live push is on for.
    func offerLivePush(_ item: ClipItem) async {
        guard let runtime, !links.isEmpty else { return }
        guard
            LivePushGate.isPushable(
                contentHash: item.contentHash,
                isConcealed: item.isConcealed,
                recentlyReceived: recentlyReceived,
                at: Date()
            )
        else { return }
        guard let meta = meta(for: item, originDeviceID: runtime.deviceID) else { return }

        let payloads = Self.wirePayloads(item)
        guard !payloads.isEmpty else { return }
        for (deviceID, link) in links where await isLivePushOn(for: deviceID) {
            await link.push(meta, payloads: payloads)
        }
    }

    /// Whether live push is on for one peer, after the user's override has been
    /// resolved against design §3's platform default.
    func isLivePushOn(for deviceID: SyncDeviceID) async -> Bool {
        // A read that fails falls back to the platform default, deliberately.
        // This runs once per peer on every capture, so it cannot report or
        // propagate without turning a locked store into a log flood or into a
        // failed capture; and the default is the setting the user has not
        // overridden, which is the safe answer to give when the override
        // cannot be read.
        let choice = (try? await trust.livePushChoice(for: deviceID)) ?? .followsPlatformDefault
        let setting = LivePushSetting(
            local: .linux,
            remote: progress[deviceID]?.platform ?? .unknown,
            choice: choice
        )
        return setting.isOn
    }

    func notifyHistoryChanged() {
        for observer in historyObservers.values { observer.yield(()) }
    }

    /// Fires once each time the history changed — captured here, learned from a
    /// peer, or submitted by a client.
    ///
    /// Carries nothing. A client that cares reads the history afterwards; a
    /// signal carrying the new item would put every clipboard entry on the
    /// session bus for subscribers that only wanted to redraw a menu, and the
    /// bus is not the place for a 30 MB image.
    ///
    /// Each caller gets its own stream and every stream sees every change, for
    /// the reason `PeerDiscovery.startBrowsing()` documents at length: one
    /// shared stream has one buffer and delivers each element to exactly one
    /// consumer, so two subscribers would split the changes between them and
    /// each miss half.
    public func historyChanges() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let id = UUID()
        historyObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeHistoryObserver(id) }
        }
        return stream
    }

    func removeHistoryObserver(_ id: UUID) {
        historyObservers[id] = nil
    }
}

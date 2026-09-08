import Foundation
import Logging
import SkrepkaCore
import SkrepkaIPC
import SkrepkaLinuxPlatform
import SkrepkaSync

#if canImport(Glibc)
    import Glibc
#endif
// For the `stat` *struct* rather than the `stat(_:_:)` function: Glibc gives
// the call, but on Linux the type is re-exported and Swift 6's
// MemberImportVisibility wants the module that declares the member — which for
// `init()` and `st_mode` is this one. Only the test target got it transitively,
// so `swift test` was green while the `SkrepkaLinux` product would not link.
#if canImport(CoreFoundation)
    import CoreFoundation
#endif

extension Daemon {
    /// What `skrepka doctor` prints, and what the Phase 7 status pane will
    /// read.
    ///
    /// Every field is measured rather than assumed, and the questions Linux
    /// does not have are absent rather than answered. What the phase plan asks
    /// this to report plainly — which backend was chosen, whether the GNOME
    /// extension is needed and missing, whether a responder is running — is
    /// what the three sections below carry.
    public func diagnosticsDocument() async -> DiagnosticsDocument {
        let network = await networkSummary()
        // Re-read on every report rather than cached at start-up: a machine
        // that has just come up often has not synchronised yet and does a
        // minute later, and a `doctor` that kept saying so would be wrong for
        // the rest of the process's life.
        clockFinding = await ClockCheck.run(over: systemBus)
        return DiagnosticsDocument(
            daemonVersion: DaemonVersion.current,
            deviceFingerprint: runtime?.deviceID.fingerprint ?? "",
            session: sessionSection(),
            network: networkSection(responder: network.responder, problem: network.problem),
            storage: await storageSection(),
            problems: await problems(network: network)
        )
    }

    private func sessionSection() -> DiagnosticsDocument.Session {
        guard let report = sessionReport else {
            return DiagnosticsDocument.Session(
                backend: nil,
                backendName: "none",
                waylandGlobals: [],
                waylandDisplay: nil,
                x11Display: nil,
                desktop: nil,
                isXWaylandFallback: false,
                problem: "the session has not been probed yet",
                isBlocking: true,
                restarts: sessionRestarts
            )
        }
        return DiagnosticsDocument.Session(
            backend: report.backend?.rawValue,
            backendName: report.backend?.displayName ?? "none",
            waylandGlobals: report.waylandGlobals,
            waylandDisplay: report.waylandDisplay,
            x11Display: report.x11Display,
            desktop: report.desktop,
            isXWaylandFallback: report.isXWaylandFallback,
            problem: report.problem?.reportLine,
            // A session on the deprecated protocol reports a problem and
            // captures perfectly well, which is the whole distinction
            // `LinuxCaptureProblem.isBlocking` exists to draw.
            isBlocking: report.problem?.isBlocking ?? false,
            restarts: sessionRestarts
        )
    }

    private func networkSection(
        responder: String,
        problem: String?
    ) -> DiagnosticsDocument.Network {
        DiagnosticsDocument.Network(
            responder: responder,
            responderProblem: problem,
            isPublished: isPublished,
            syncPort: syncServer.map { UInt16($0.port) },
            pairedCount: links.count,
            sightedCount: sighted.count
        )
    }

    private func storageSection() async -> DiagnosticsDocument.Storage {
        let path = options.storeURL(environment: environment).path
        var itemCount = 0
        do {
            itemCount = try await store.listing().count
        } catch {
            // Reported and then counted as zero. `Storage.itemCount` is an
            // `Int` with nowhere to say "unknown", and a report that refused
            // to render because one of its six lines failed would hide the
            // other five — which is the opposite of what `skrepka doctor` is
            // for.
            logger.error(
                "could not count the stored items for the diagnostics report",
                metadata: ["error": .string(String(describing: error))]
            )
        }
        return DiagnosticsDocument.Storage(
            path: path,
            itemCount: itemCount,
            lastCapturedAt: lastCapturedAt,
            mode: Self.fileMode(path)
        )
    }

    /// The file's permission bits as four octal characters.
    ///
    /// Reported because the store holds the plainest copy of everything the
    /// user has ever copied, in the clear, and a mode that drifted is not
    /// something anyone checks by hand. `????` for a file that cannot be
    /// stat'ed, which is itself worth seeing.
    static func fileMode(_ path: String) -> String {
        var status = stat()
        guard stat(path, &status) == 0 else { return "????" }
        return String(format: "%04o", status.st_mode & 0o7777)
    }

    // MARK: - What is actually wrong

    /// The problems worth putting in front of the user, most serious first.
    ///
    /// Empty is an answer, and it is the answer that makes `doctor` worth
    /// running. Nothing here restates a fact from the sections above; a problem
    /// is a sentence with a remedy in it.
    private func problems(network: (responder: String, problem: String?)) async -> [String] {
        var found: [String] = []

        if let report = sessionReport, report.problem?.isBlocking == true {
            found.append(report.problem?.reportLine ?? "this session cannot be watched")
        } else if sessionReport?.backend == nil {
            found.append(
                """
                Nothing in this session can be watched, so nothing is being captured. \
                Run `skrepka doctor --json` and include the session block in a bug report.
                """
            )
        }
        if sessionReport?.isXWaylandFallback == true {
            found.append(
                """
                Capturing through XWayland, which sees only what X11 applications copy — \
                anything copied from a native Wayland application is invisible.
                """
            )
        }
        if let problem = network.problem, options.syncEnabled {
            found.append("Peers cannot be found: \(problem)")
        }
        if options.syncEnabled, network.problem == nil, !isPublished {
            found.append(
                """
                This device is not published on the local network, so no peer can find it. \
                A firewall is the usual cause — Fedora ships firewalld active, which blocks \
                mDNS by default.
                """
            )
        }
        found.append(contentsOf: await pairingProblems())
        return found
    }

    /// Problems that are about paired peers rather than about this machine.
    private func pairingProblems() async -> [String] {
        var found: [String] = []
        let unreachable = links.keys.filter { sighted[$0] == nil }
        if !unreachable.isEmpty, isPublished {
            let names = unreachable.map(\.fingerprint).sorted().joined(separator: ", ")
            found.append(
                """
                Paired but not on the network right now: \(names). \
                Either the peer is asleep, or the two machines are on different networks.
                """
            )
        }
        // The merge model tolerates clock skew everywhere except the pin
        // register, whose last-writer-wins is only as good as the two clocks —
        // so a machine that has never run NTP can hold a pin state hostage, and
        // `InboundClock` will silently refuse its clippings besides.
        //
        // Asked of this machine rather than measured against a peer, because
        // the wire carries no timestamp to measure against. See ``ClockCheck``.
        if let clock = clockFinding?.problem { found.append(clock) }
        return found.sorted()
    }
}

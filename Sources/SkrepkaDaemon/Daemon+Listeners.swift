import Foundation
import Logging
import SkrepkaSync

/// Binding the two listeners on the ports ``ListenerPorts`` names.
///
/// Its own file because `Daemon+Pairing.swift` sits at the 300-line ceiling
/// `swift-conventions.md` sets, and because both listeners bind the same way:
/// the port `--port` asked for, or Skrepka's own pair with a free port behind
/// it when another program got there first.
extension Daemon {
    /// The ports `--port` asked for, or Skrepka's own pair.
    var listenerPorts: ListenerPorts { ListenerPorts(configured: options.port) }

    /// Binds the pinned listener on `port`, accepting only `pinned`.
    func bindPinnedListener(
        runtime: SyncRuntime,
        port: Int,
        pinned: Set<SyncDeviceID>
    ) async throws -> SyncServer {
        let server = try await listenerPorts.bind(port) { port in
            try await SyncServer.start(
                identity: runtime.certificate,
                policy: .pinned(pinned),
                host: Self.listenHost,
                port: port,
                group: runtime.group
            )
        }
        noteFallback(listener: "sync", wanted: port, bound: server.port)
        return server
    }

    /// Binds the pairing listener on the port after the sync one.
    func bindPairingListener(runtime: SyncRuntime) async throws -> SyncServer {
        let wanted = listenerPorts.pairing
        let server = try await listenerPorts.bind(wanted) { port in
            try await SyncServer.start(
                identity: runtime.certificate,
                policy: .pairing,
                host: Self.listenHost,
                port: port,
                group: runtime.group
            )
        }
        noteFallback(listener: "pairing", wanted: wanted, bound: server.port)
        return server
    }

    /// Says so in the journal when a listener did not get the port it asked
    /// for, because a firewall rule written for that port no longer covers it.
    /// `skrepka doctor` says it again for as long as it is true — see
    /// ``listenerPortProblems()``.
    private func noteFallback(listener: String, wanted: Int, bound: Int) {
        guard wanted != 0, bound != wanted else { return }
        logger.notice(
            """
            another program holds TCP port \(wanted), so the \(listener) listener took \(bound) \
            instead; a firewall rule written for port \(wanted) does not cover it
            """,
            metadata: ["wanted": .stringConvertible(wanted), "bound": .stringConvertible(bound)]
        )
    }

    /// What `skrepka doctor` says about the listeners' ports: one line per
    /// listener that is not on the port it asked for.
    func listenerPortProblems() -> [String] {
        let ports = listenerPorts
        return [
            Self.portProblem(listener: "sync", wanted: ports.sync, bound: syncServer?.port),
            Self.portProblem(listener: "pairing", wanted: ports.pairing, bound: pairingServer?.port),
        ].compactMap { $0 }
    }

    private static func portProblem(listener: String, wanted: Int, bound: Int?) -> String? {
        guard wanted != 0, let bound, bound != wanted else { return nil }
        return """
            Another program holds TCP port \(wanted), so Skrepka listens for \(listener) on \
            \(bound) instead — a firewall rule written for port \(wanted) does not cover it. \
            Stop whatever holds \(wanted) (`ss -ltnp 'sport = :\(wanted)'` names it), then \
            restart skrepkad.
            """
    }
}

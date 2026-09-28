import Foundation
import NIOCore
import SkrepkaIPC
import SkrepkaSync

#if canImport(Glibc)
    import Glibc
#endif

/// The two TCP ports skrepkad listens on, and what happens when one is taken.
///
/// Fixed by default rather than whatever the kernel hands out, because a port
/// that changes on every start is one no firewall rule can name. NixOS ships
/// its firewall on and dropping, so a Mac dialling a NixOS machine on a random
/// port waited out its ten-second connect timeout and said "Could not
/// connect" — while the same two machines paired fine the other way round,
/// because a Linux machine's own dials leave through its firewall and their
/// answers come back in on the connection it opened.
///
/// ``SkrepkaPorts`` — 27182 and 27183 — are unassigned in the IANA registry and
/// sit below Linux's ephemeral range (32768–60999), so no outgoing connection
/// is ever holding one when the daemon starts. The pairing listener takes the
/// port after the sync one so that one rule covers both: `27182-27183/tcp`.
/// The NixOS module's `openFirewall` opens exactly that.
struct ListenerPorts: Sendable, Hashable {
    /// The sync port when `--port` does not name one.
    static let defaultSync = SkrepkaPorts.sync

    /// The pinned listener's port. `0` asks for any free one.
    let sync: Int

    /// The pairing listener's port. `0` asks for any free one.
    let pairing: Int

    /// Whether a port another program already holds may be traded for a free
    /// one.
    ///
    /// Only Skrepka's own pair may. A daemon that refused to start because some
    /// other program sat on 27182 would take capture down with sync, and a
    /// listener on a free port still serves every peer this device dials and
    /// every peer whose firewall lets it through. A port the user named is
    /// different: it is what their firewall rule says, so it binds exactly or
    /// the daemon says why it could not.
    let mayFallBack: Bool

    init(configured: Int?) {
        let base = configured ?? Self.defaultSync
        sync = base
        pairing = base == 0 ? 0 : base + 1
        mayFallBack = configured == nil
    }

    /// Binds `port` through `start`, or a free port when that one is taken and
    /// ``mayFallBack`` allows it.
    ///
    /// Only `EADDRINUSE` falls back. Anything else — a permission error, an
    /// address this machine does not have — is not "somebody else got there
    /// first", and a free port would not fix it.
    func bind(
        _ port: Int,
        start: (Int) async throws -> SyncServer
    ) async throws -> SyncServer {
        do {
            return try await start(port)
        } catch let error as IOError where error.errnoCode == EADDRINUSE && mayFallBack && port != 0 {
            return try await start(0)
        }
    }
}

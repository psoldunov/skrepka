import Foundation
import SkrepkaSync

/// Turns a sync failure into a sentence for the Sync settings pane.
///
/// The repo's rule is that errors reaching the user get a message written for a
/// user rather than a `localizedDescription` dump, and none of `SkrepkaSync`'s
/// error types is `LocalizedError` — that target builds on Linux and owns no
/// user-facing copy. So the translation lives here, where the pane that shows it
/// does.
///
/// Only the failures a user can act on are named. Everything else falls through
/// to a plain "could not connect", because a peer that is asleep, a Wi-Fi
/// network that has changed and a laptop that closed its lid all arrive as
/// unrelated NIO errors and none of them is worth a paragraph. The
/// `CustomStringConvertible` description each of these types already carries is
/// what goes to the log; this is what goes on screen.
///
/// `nonisolated` against the app target's default main-actor isolation: a
/// `PeerLink` runs off the main actor and takes this as a plain `@Sendable`
/// function, and nothing here touches state to need the hop.
nonisolated enum SyncFailureText {
    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as SyncTLSError: describe(error)
        case let error as PairingError: describe(error)
        case is DiscoveryError: "Could not find this device on the network."
        default: "Could not connect."
        }
    }

    private static func describe(_ error: SyncTLSError) -> String {
        switch error {
        case .unpinnedCertificate:
            """
            This device presented a different identity than the one you paired \
            with. Unpair and pair again if Skrepka was reinstalled on it.
            """
        case .handshakeTimedOut, .handshakeIncomplete:
            "The secure connection did not complete."
        case .verificationDisabled, .minimumVersionTooLow, .emptyCertificateChain,
            .peerCertificateUnreadable:
            "The secure connection was refused."
        }
    }

    private static func describe(_ error: PairingError) -> String {
        switch error {
        case .reachedTheWrongPeer, .identityChangedInsideTunnel,
            .certificateDoesNotMatchTunnel, .certificateDoesNotMatchClaim:
            """
            The connection reached a different device than the one it was for. \
            Nothing was synced.
            """
        case .protocolDowngrade, .protocolVersionChangedInsideTunnel:
            """
            This device is offering an older protocol than it used before, so \
            Skrepka refused it.
            """
        case .rejectedByPeer:
            "The other device turned down the pairing."
        case .shortAuthenticationStringMismatch:
            """
            The two devices showed different codes, so pairing was stopped. \
            Try again, and if it happens twice do not pair on this network.
            """
        case .stalePairingTimestamp:
            "The pairing took too long to confirm. Start it again."
        case .selfPairing:
            "That is this device."
        }
    }
}

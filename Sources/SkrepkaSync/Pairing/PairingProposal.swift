import Foundation

/// A pairing that is one human confirmation away from being saved.
///
/// The two halves travel together because neither is safe alone: saving the
/// peer without the user having compared the string trusts whatever answered
/// the connection, and showing the string without holding the record it belongs
/// to invites saving a different one.
public struct PairingProposal: Sendable, Hashable {
    /// What ``PairedDeviceStoring/savePairedPeer(_:)`` is handed if the user says yes.
    public let peer: PairedPeer
    /// The eight characters the user compares against the other screen, already
    /// rendered — `A3F2-91BC`. See ``ShortAuthString``.
    public let shortAuthenticationString: String

    public init(peer: PairedPeer, shortAuthenticationString: String) {
        self.peer = peer
        self.shortAuthenticationString = shortAuthenticationString
    }
}

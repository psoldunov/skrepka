import Foundation

/// Where the record of a paired device lives, and where the anti-downgrade
/// high-water mark lives with it.
///
/// Split out of ``TrustStore`` because the two halves are persisted in
/// different places on macOS: the private key belongs in the Keychain, and the
/// peer records belong in the same SwiftData container as the clipboard
/// history, next to the `PairedDeviceRecord` that backs them. Composing two
/// protocols is what lets `KeychainTrustStore` own the first half and delegate
/// the second without either one knowing about the other's storage.
///
/// `SkrepkaSync` must build on Linux and therefore cannot import
/// `SkrepkaCore`, so this is the shape the app target's store conforms to.
/// Every requirement is `async`: the conforming store is `@MainActor` because
/// it owns `ModelContainer.mainContext`, and a connection actor cannot ask it
/// anything synchronously.
public protocol PairedDeviceStoring: Sendable {
    func pairedPeers() async throws -> [PairedPeer]
    func pairedPeer(_ deviceID: SyncDeviceID) async throws -> PairedPeer?

    /// Inserts or replaces the record for `peer.deviceID`.
    func savePairedPeer(_ peer: PairedPeer) async throws

    /// Removes the peer *and* its high-water mark. A forgotten device is a
    /// stranger again, which is what makes re-pairing meaningful — leaving the
    /// mark behind would have a reinstalled peer refused for a downgrade it
    /// never made.
    func forgetPairedPeer(_ deviceID: SyncDeviceID) async throws

    /// The highest protocol version this peer has ever advertised, or nil when
    /// it has never connected.
    ///
    /// Kept apart from ``PairedPeer`` because the rest of a peer's record is
    /// written once, at pairing, and this is written on every handshake.
    /// Folding it in would mean a read-modify-write of the whole record per
    /// connection and two writers for one row.
    func highestProtocolVersion(for deviceID: SyncDeviceID) async throws -> ProtocolVersion?

    /// Raises the mark for `deviceID` to `version` when it is higher, and does
    /// nothing when it is not.
    ///
    /// **Never lowers it.** That is the whole point of a high-water mark, and a
    /// conformance that lowers it defeats
    /// ``PairingSession/verifyNoDowngrade(offered:remembered:)`` without
    /// failing anything.
    func recordProtocolVersion(_ version: ProtocolVersion, for deviceID: SyncDeviceID) async throws
}

extension PairedDeviceStoring {
    /// The set a ``PinPolicy/pinned(_:)`` is built from.
    ///
    /// Read once before a connection is made, because the TLS verification
    /// callback runs on an event loop and cannot await a store.
    public func pinnedDeviceIDs() async throws -> Set<SyncDeviceID> {
        Set(try await pairedPeers().map(\.deviceID))
    }
}

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

    /// Whether the user has overridden design §3's live-push default for this
    /// peer, and which way.
    ///
    /// ``LivePushChoice/followsPlatformDefault`` for a peer nobody has chosen
    /// for, and for one that is not paired at all — the same answer, because
    /// neither has a recorded choice and the caller resolves both against
    /// ``LivePushDefault``.
    ///
    /// Kept apart from ``PairedPeer`` for the reason
    /// ``highestProtocolVersion(for:)`` is: the rest of a peer's record is
    /// written once at pairing, and this is written whenever the user flips a
    /// switch. Folding it in would mean a read-modify-write of the pinning
    /// material to change a preference.
    func livePushChoice(for deviceID: SyncDeviceID) async throws -> LivePushChoice

    /// Records the user's choice for one peer, or clears it back to the
    /// platform default.
    ///
    /// Does nothing for a device that is not paired: there is no record to
    /// write on, and inventing one would create a trusted peer out of a
    /// preference. The choice goes with the peer at
    /// ``forgetPairedPeer(_:)``, which is the whole reason it lives here rather
    /// than in a preferences file keyed by device identifier — that would
    /// outlive the pairing and silently re-apply if the same machine paired
    /// again.
    func setLivePushChoice(_ choice: LivePushChoice, for deviceID: SyncDeviceID) async throws
}

extension PairedDeviceStoring {
    /// Updates a paired peer's name and platform from the identity it proved
    /// inside the tunnel.
    ///
    /// **The advisory half of a peer record is written at the wrong moment
    /// otherwise, and one of the two fields is load-bearing.** A device that
    /// dials to pair learns nothing about the peer except its certificate: the
    /// peer's name and platform arrive in `hello`, which a
    /// ``PinPolicy/pairing`` connection may not carry, so
    /// ``SyncInitiator/pair(at:)`` records the fingerprint as a name and
    /// ``PeerPlatform/unknown`` as a platform. The name is cosmetic; the
    /// platform decides the live-push default, and `unknown` means off — so the
    /// side that *initiated* the pairing would silently never push, for ever,
    /// to a Linux peer.
    ///
    /// Called from both ends of the handshake, where the identity has been
    /// checked against the certificate the connection was made with.
    ///
    /// **Cannot repin.** The certificate is taken from the stored record rather
    /// than from the caller, so this can move a name and a platform and nothing
    /// else. A device that is not paired is left alone: an identity is not an
    /// approval, and creating a record here would make one out of a handshake.
    ///
    /// ``PairedPeer/pairedAt`` is preserved, so a peer that reconnects does not
    /// have its pairing date rewritten to today.
    public func refreshPeerIdentity(_ identity: PeerIdentity) async throws {
        guard let held = try await pairedPeer(identity.deviceID) else { return }
        guard held.deviceName != identity.deviceName || held.platform != identity.platform
        else { return }
        try await savePairedPeer(
            PairedPeer(
                certificateDER: held.certificateDER,
                deviceName: identity.deviceName,
                platform: identity.platform,
                pairedAt: held.pairedAt
            )
        )
    }

    /// The set a ``PinPolicy/pinned(_:)`` is built from.
    ///
    /// Read once before a connection is made, because the TLS verification
    /// callback runs on an event loop and cannot await a store.
    public func pinnedDeviceIDs() async throws -> Set<SyncDeviceID> {
        Set(try await pairedPeers().map(\.deviceID))
    }
}

import Foundation
import SkrepkaCore
import SkrepkaSync
import os

/// First contact: the sheet, the answer, and what saving one costs.
extension SyncCoordinator {
    // MARK: - Answering a peer that dialled us

    /// Puts an incoming proposal on screen and waits for the user.
    ///
    /// This is the whole man-in-the-middle defence, so it can only ever be
    /// answered by a person — see `PairingConfirmation`. It parks until
    /// ``answerPairing(_:)`` is called, which is why the responder that awaits
    /// it runs in a task of its own.
    ///
    /// **One at a time.** A second proposal arriving while a sheet is open is
    /// refused rather than queued: stacking approval prompts is how a user is
    /// worn into confirming one without reading it, and the string on screen is
    /// worth nothing to a user who has stopped comparing it.
    func confirmPairing(
        _ proposal: PairingProposal,
        direction: PendingPairing.Direction
    ) async -> Bool {
        guard pendingPairing == nil, !isPairingInFlight else { return false }
        let pending = PendingPairing(
            direction: direction,
            peerName: proposal.peer.deviceName,
            fingerprint: proposal.peer.deviceID.fingerprint,
            code: proposal.shortAuthenticationString,
            stage: .awaitingConfirmation
        )
        pendingPairing = pending
        let accepted = await withCheckedContinuation { continuation in
            pairingAnswer = continuation
        }
        pendingPairing = nil
        if accepted {
            // The responder saves the peer itself on the inbound path; this
            // covers both and is idempotent, since saving is an upsert.
            await pairedSetMayHaveChanged()
        }
        return accepted
    }

    /// The user's answer to whatever sheet is open.
    func answerPairing(_ accepted: Bool) {
        guard let continuation = pairingAnswer else {
            pendingPairing = nil
            return
        }
        pairingAnswer = nil
        continuation.resume(returning: accepted)
    }

    /// Closes a sheet that has nothing left to ask, without answering anything.
    func dismissPairing() {
        guard pairingAnswer == nil else {
            answerPairing(false)
            return
        }
        pendingPairing = nil
    }

    // MARK: - Dialling a peer to pair with it

    /// Pairs with a device seen on the network.
    ///
    /// The code goes on screen before the request is sent, because this device
    /// can derive it from what it already holds — its own public key, the leaf
    /// the peer presented, and the timestamp it chose. Waiting for the peer's
    /// reply to show it would leave this user staring at a blank sheet while the
    /// other user is already comparing, which is exactly when somebody clicks
    /// through.
    ///
    /// The connection is made under ``PinPolicy/pairing``, which cannot carry
    /// anything except the two pairing messages, and it is closed whatever
    /// happens: first contact is one request and one confirm, and a connection
    /// left open past that is one an unauthenticated peer can raise a second
    /// sheet on.
    func pair(with deviceID: SyncDeviceID) async {
        guard pendingPairing == nil, !isPairingInFlight else { return }
        guard let runtime, let sighting = sighted[deviceID] else { return }
        guard let pairingPort = sighting.advertisement.pairingPort else {
            errorMessage = "\(rowName(for: deviceID)) is not accepting new pairings right now."
            return
        }
        // Reserved before the first `await`, so a peer dialling in while this is
        // resolving and handshaking cannot take the sheet out from under it.
        isPairingInFlight = true
        defer { isPairingInFlight = false }
        do {
            try await runPairing(with: sighting, port: pairingPort, runtime: runtime)
        } catch {
            finish(pairing: .ended(reason: SyncFailureText.describe(error)))
            SkrepkaLog.sync.error(
                "Pairing failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func runPairing(
        with sighting: SightedPeer,
        port: UInt16,
        runtime: SyncRuntime
    ) async throws {
        let resolved = try await resolve(sighting.advertisement.deviceID)
        let connection = try await SyncClient.connect(
            host: resolved.host,
            port: Int(port),
            identity: runtime.certificate,
            policy: .pairing,
            group: runtime.group
        )
        defer { Task { await connection.close() } }

        let pairedAt = Date()
        let pending = try showOutgoingSheet(
            for: connection,
            sighting: sighting,
            pairedAt: pairedAt,
            runtime: runtime
        )

        // `expecting: nil` because this is first contact: nothing is pinned yet,
        // so there is no identifier to have expected.
        let initiator = try SyncInitiator(
            connection: connection,
            session: runtime.pairing,
            trust: runtime.trust,
            expecting: nil
        )
        let proposal = try await initiator.pair(at: pairedAt)
        guard pendingPairing === pending else { return }
        pending.stage = .awaitingConfirmation

        let accepted = await withCheckedContinuation { continuation in
            pairingAnswer = continuation
        }
        pendingPairing = nil
        guard accepted else { return }
        try await runtime.trust.savePairedPeer(proposal.peer)
        await pairedSetMayHaveChanged()
    }

    /// Shows the code this side derived, before anything is sent.
    ///
    /// Derived from ``SyncConnection/peerCertificateDER`` — the leaf the peer
    /// actually completed the handshake with — rather than from anything it will
    /// claim in a message, which is the same binding
    /// ``PairingSession/proposal(for:presentedCertificateDER:now:)`` makes on
    /// the other side. ``SyncInitiator/pair(at:)`` re-derives it and refuses a
    /// `pairConfirm` that disagrees, so this is a display of the value rather
    /// than a second source of it.
    private func showOutgoingSheet(
        for connection: SyncConnection,
        sighting: SightedPeer,
        pairedAt: Date,
        runtime: SyncRuntime
    ) throws -> PendingPairing {
        let peerKey = try DeviceCertificate.publicKeyBytes(
            fromCertificateDER: connection.peerCertificateDER
        )
        let pending = PendingPairing(
            direction: .outgoing,
            peerName: sighting.advertisement.displayName ?? sighting.peer.instanceName,
            fingerprint: connection.peerDeviceID.fingerprint,
            code: ShortAuthString.derive(
                publicKeys: [runtime.certificate.publicKeyBytes, peerKey],
                pairedAt: pairedAt
            ),
            stage: .waitingForPeer
        )
        pendingPairing = pending
        return pending
    }

    private func finish(pairing stage: PendingPairing.Stage) {
        pairingAnswer?.resume(returning: false)
        pairingAnswer = nil
        pendingPairing?.stage = stage
    }

    // MARK: - Forgetting

    /// Unpairs a device: the pin goes, the link goes, and the listener stops
    /// accepting it.
    func unpair(_ deviceID: SyncDeviceID) async {
        guard let runtime else { return }
        do {
            try await runtime.trust.forgetPairedPeer(deviceID)
        } catch {
            errorMessage = "Skrepka could not forget that device."
            SkrepkaLog.sync.error(
                "Unpairing failed: \(String(describing: error), privacy: .public)"
            )
            return
        }
        await pairedSetMayHaveChanged()
    }
}

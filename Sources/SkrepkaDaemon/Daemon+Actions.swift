import Foundation
import Logging
import SkrepkaCore
import SkrepkaIPC
import SkrepkaLinuxPlatform
import SkrepkaSync

extension Daemon {
    /// Records a clip a client observed and this daemon could not.
    ///
    /// **The GNOME path.** Mutter implements no data-control protocol, so on a
    /// GNOME Wayland session `SessionProbe` finds nothing to watch and capture
    /// is dead; the Phase 8 Shell extension runs inside the compositor, where
    /// it can see a copy happen, and this is how it hands one over.
    ///
    /// The daemon applies its own `CaptureRules` to what arrives rather than
    /// trusting the client. A submission is a clipboard change from an
    /// untrusted-ish source on the same bus, and the exclusion list, the size
    /// ceiling and the privacy markers are exactly as relevant to it as to one
    /// the daemon read itself.
    public func submit(_ request: SubmitRequest) async -> ActionDocument {
        guard let payloads = request.decodedRepresentations() else {
            return .refused("one of the representations was not valid base64")
        }
        let total = payloads.values.reduce(0) { $0 + $1.count }
        guard total <= SubmitRequest.sizeLimit else {
            return .refused("that clip is \(total) bytes, over the \(SubmitRequest.sizeLimit) limit")
        }
        guard !payloads.isEmpty else { return .refused("the submission carried no representations") }

        let snapshot = LinuxSubmission.snapshot(
            representations: payloads,
            sourceApplication: request.sourceApplication,
            isConcealed: request.isConcealed
        )
        let decision = CaptureRules().decide(snapshot)
        guard let item = decision.item else {
            return .refused(decision.rejectionLogMessage ?? "nothing in that clip could be recorded")
        }
        guard await store.capture(item) else {
            return .succeeded("already held", subject: item.contentHash)
        }
        lastCapturedAt = Date()
        notifyHistoryChanged()
        await offerLivePush(item)
        return .succeeded("recorded", subject: item.contentHash)
    }

    /// Dials a peer this device has seen, and parks until somebody confirms.
    ///
    /// Returns as soon as there is a short authentication string to show. The
    /// caller then compares it against the other machine's screen and calls
    /// ``answerPairing(deviceID:accept:)`` — which is what actually completes
    /// the pairing, because the string is the whole of the protection against
    /// a device in the middle.
    ///
    /// The whole dial-and-pair runs under ``Daemon/pairDialTimeout``. Neither
    /// `SyncClient.connect` nor `SyncInitiator.pair(at:)` bounds itself, and
    /// the daemon's bus connection answers one call at a time — so a peer that
    /// completes the TCP connect and then goes quiet would hang not just this
    /// call but every `History`, `Copy` and `Diagnostics` behind it.
    public func pair(withFingerprint fingerprint: String) async throws -> PairingProposalDocument {
        guard let runtime else { throw PairingWindowError.syncIsOff }
        guard let sighting = Self.sighting(matching: fingerprint, in: sighted) else {
            throw PairError.notOnTheNetwork(fingerprint)
        }
        guard let pairingPort = sighting.advertisement.pairingPort else {
            throw PairError.notAcceptingPairing(fingerprint)
        }
        guard let discovery else { throw PairError.notOnTheNetwork(fingerprint) }

        let proposal = try await boundedDial(
            to: sighting,
            port: pairingPort,
            runtime: runtime,
            discovery: discovery,
            fingerprint: fingerprint
        )

        let (answers, sink) = AsyncStream<Bool>.makeStream()
        let waiting = PendingPairing(
            proposal: proposal,
            direction: PairingDirection.outgoing,
            expiresAt: Date().addingTimeInterval(pairingAnswerTimeout.seconds),
            sink: sink
        )
        // One live proposal per peer, and both writers obey it — see
        // `confirmPairing(_:direction:)`, which expires the same way.
        // Overwriting without expiring parked whichever proposal it displaced
        // for the whole timeout with nothing able to answer it, because
        // `answerPairing(deviceID:accept:)` finds only the survivor.
        pending[proposal.peer.deviceID]?.expire()
        pending[proposal.peer.deviceID] = waiting
        watchOutgoingAnswer(answers, proposal: proposal, proposalID: waiting.id)
        return waiting.document
    }

    /// Resolves the peer and dials it, under ``Daemon/pairDialTimeout``.
    ///
    /// Split out of ``pair(withFingerprint:)`` so both stay inside the 40-line
    /// body the lint rule allows; the deadline is the whole point of it, so the
    /// two belong to one another rather than being independently useful.
    private func boundedDial(
        to sighting: Sighting,
        port pairingPort: UInt16,
        runtime: SyncRuntime,
        discovery: any PeerDiscovery,
        fingerprint: String
    ) async throws -> PairingProposal {
        let expected = sighting.advertisement.deviceID
        let peer = sighting.peer
        do {
            return try await Deadline.run(
                Self.pairDialTimeout,
                expiry: PairError.tookTooLong(fingerprint)
            ) {
                let resolved = try await discovery.resolve(peer)
                return try await Self.dial(
                    host: resolved.host,
                    port: Int(pairingPort),
                    runtime: runtime,
                    expecting: expected
                )
            }
        } catch let error as PairError {
            // The abandoned dial may still land: the far side's
            // `confirmPairing` then shows a proposal this side has already
            // given up on, and accepting it there records us as a peer while
            // nothing here has a record of it. Said in the error and written
            // to the journal, because the honest fix — carrying a late success
            // into `completeOutgoing` — is bigger than this.
            logger.notice(
                "a dial to pair was abandoned; the far device may still be prompting",
                metadata: ["peer": .string(fingerprint)]
            )
            throw error
        }
    }

    /// Opens the pairing connection, runs the exchange, and closes it either
    /// way.
    ///
    /// `nonisolated static` because it is run from inside ``Deadline/run(_:expiry:operation:)``
    /// and must not hold the actor for the length of a network round trip. The
    /// close is written twice rather than deferred: `defer` may not `await`.
    private nonisolated static func dial(
        host: String,
        port: Int,
        runtime: SyncRuntime,
        expecting: SyncDeviceID
    ) async throws -> PairingProposal {
        let connection = try await SyncClient.connect(
            host: host,
            port: port,
            identity: runtime.certificate,
            // The dialling side has nothing pinned — that is what pairing is —
            // so this connection is under the policy that permits `pairRequest`
            // and `pairConfirm` and nothing else.
            policy: .pairing,
            group: runtime.group
        )
        do {
            let initiator = try SyncInitiator(
                connection: connection,
                session: runtime.pairing,
                trust: runtime.trust,
                expecting: expecting
            )
            let proposal = try await initiator.pair(at: Date())
            await connection.close()
            return proposal
        } catch {
            await connection.close()
            throw error
        }
    }

    /// Saves the peer if the answer was yes, and forgets the proposal either
    /// way.
    ///
    /// Separate from the inbound path because the two record the pairing at
    /// different moments: `SyncResponder` writes the peer itself once its
    /// `confirmPairing` returns true, and the dialling side has already
    /// finished its exchange by the time a human looks at the words — so this
    /// side has to write the record here or nowhere.
    private func watchOutgoingAnswer(
        _ answers: AsyncStream<Bool>,
        proposal: PairingProposal,
        proposalID: UUID
    ) {
        Task { [weak self] in
            guard let self else { return }
            let accepted = await Self.firstOutgoingAnswer(
                answers, timeout: self.pairingAnswerTimeout)
            await self.completeOutgoing(proposal, proposalID: proposalID, accepted: accepted)
        }
    }

    private nonisolated static func firstOutgoingAnswer(
        _ answers: AsyncStream<Bool>,
        timeout: Duration
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await answer in answers { return answer }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
    }

    func completeOutgoing(
        _ proposal: PairingProposal,
        proposalID: UUID,
        accepted: Bool
    ) async {
        forget(proposal.peer.deviceID, proposalID: proposalID)
        guard accepted else { return }
        do {
            try await trust.savePairedPeer(proposal.peer)
            await pairedSetMayHaveChanged()
        } catch {
            logger.error(
                "could not record a paired device",
                metadata: ["error": .string(String(describing: error))]
            )
        }
    }

    /// Forgets a paired device.
    public func unpair(fingerprint: String) async -> ActionDocument {
        let paired: [PairedPeer]
        do {
            paired = try await trust.pairedPeers()
        } catch {
            // Surfaced rather than discarded: an empty list here reads as "no
            // paired device matches that", which is a different answer from
            // "the store could not be read" and sends the user hunting for a
            // fingerprint that is fine.
            return .refused("could not read the paired devices: \(error)")
        }
        let matches =
            paired.filter { $0.deviceID.hex.hasPrefix(fingerprint.lowercased()) }
            + paired.filter { $0.deviceID.fingerprint == fingerprint }
        guard let peer = Set(matches.map(\.deviceID)).count == 1 ? matches.first : nil else {
            return matches.isEmpty
                ? .refused("no paired device matches \"\(fingerprint)\"")
                : .refused("\"\(fingerprint)\" matches more than one paired device")
        }
        do {
            try await trust.forgetPairedPeer(peer.deviceID)
        } catch {
            return .refused("could not forget it: \(error)")
        }
        await pairedSetMayHaveChanged()
        return .succeeded("forgot \(peer.deviceName)", subject: peer.deviceID.fingerprint)
    }

    static func sighting(
        matching fingerprint: String,
        in sighted: [SyncDeviceID: Sighting]
    ) -> Sighting? {
        let wanted = fingerprint.lowercased()
        let matches = sighted.filter {
            $0.key.hex.hasPrefix(wanted) || $0.key.fingerprint.lowercased() == wanted
        }
        // Exactly one, or nothing. Pairing with whichever of two peers a short
        // prefix happened to hit is the one mistake this whole handshake exists
        // to make impossible.
        return matches.count == 1 ? matches.values.first : nil
    }
}

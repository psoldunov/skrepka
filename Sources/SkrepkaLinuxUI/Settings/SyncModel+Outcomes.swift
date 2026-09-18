import Foundation
import SkrepkaIPC

// What each finished action and each incoming proposal means for the window.
// Split from `SyncModel.swift` so the state and its generic transitions read
// on their own, and each outcome here can be read against the daemon member
// that produced it.
extension SyncModel {
    func finishing(
        _ action: SyncAction,
        _ result: ActionResult,
        refreshed document: PeersDocument?,
        now: Date
    ) -> SyncTransition {
        let settled = withoutInFlight(action)
        let current = document.map(settled.refreshed) ?? settled
        switch action {
        case .pair(let deviceID):
            return current.dialled(deviceID, result)
        case .answer(let deviceID, let accept):
            return current.answered(deviceID, accept: accept, result, now: now)
        case .openPairingWindow, .closePairingWindow:
            return SyncTransition(model: current.pairingWindowChanged(result))
        case .unpair, .setLivePush, .syncNow:
            return SyncTransition(model: current.reported(action, result, now: now))
        }
    }

    /// A peer dialled this device.
    ///
    /// One prompt at a time: a second device waits its turn rather than
    /// replacing the code somebody is halfway through comparing. The same
    /// device dialling again replaces its own prompt — the daemon has already
    /// expired the older proposal, so its code can no longer be answered —
    /// unless an answer to it is already on its way, which settles the new one
    /// too: the daemon answers whichever proposal it holds for the device.
    func requested(_ proposal: PairingProposalDocument, now: Date) -> SyncTransition {
        // Only incoming proposals arrive this way. An outgoing one is the
        // answer to a dial, and reaches ``dialled(_:_:)`` instead.
        guard proposal.direction == PairingProposalDocument.Direction.incoming,
            proposal.expiresAt > now
        else { return SyncTransition(model: self) }
        guard let prompt else { return SyncTransition(model: withPrompt(.comparing(proposal))) }
        guard prompt.deviceID == proposal.deviceID else {
            let others = waiting.filter { $0.deviceID != proposal.deviceID }
            return SyncTransition(model: withWaiting(others + [proposal]))
        }
        if prompt.direction == .outgoing, !prompt.isOver {
            return crossed(prompt)
        }
        if case .answering = prompt.stage {
            return SyncTransition(model: self)
        }
        return SyncTransition(model: withPrompt(.comparing(proposal)))
    }

    /// Both devices dialled each other at once.
    ///
    /// The daemon keeps one proposal per device and answers whichever it holds
    /// when the answer arrives, so with two in flight nobody can know which
    /// code a "yes" would confirm. Both are refused — this one now, the dial's
    /// own when it lands — and the person starts again from one side.
    private func crossed(_ prompt: PairingPrompt) -> SyncTransition {
        SyncTransition(
            model: withPrompt(prompt.moved(to: .ended(PairingPrompt.crossed))),
            effects: [.answer(deviceID: prompt.deviceID, accept: false)]
        )
    }

    /// The next peer in line, once nothing is being asked.
    func promotingWaiting(now: Date) -> SyncModel {
        guard prompt == nil else { return self }
        let live = waiting.filter { $0.expiresAt > now }
        guard let next = live.first else { return withWaiting([]) }
        return withWaiting(Array(live.dropFirst())).withPrompt(.comparing(next))
    }

    // MARK: - Pairing

    private func dialled(_ deviceID: String, _ result: ActionResult) -> SyncTransition {
        let isDialling = prompt.map { $0.deviceID == deviceID && $0.stage == .dialling } ?? false
        switch result {
        case .proposed(let proposal):
            guard isDialling, let prompt else {
                // The dial was cancelled while it ran. The daemon now holds a
                // proposal nobody will compare, so it is refused at once
                // rather than left to time out.
                return SyncTransition(
                    model: self, effects: [.answer(deviceID: proposal.deviceID, accept: false)])
            }
            return SyncTransition(model: withPrompt(.comparing(proposal, knownName: prompt.name)))
        case .failed(let failure):
            return SyncTransition(model: isDialling ? ended(failure.message) : self)
        case .answered(let document) where !document.ok:
            return SyncTransition(model: isDialling ? ended(SyncText.sentence(document.detail)) : self)
        case .answered, .opened:
            return SyncTransition(model: self)
        }
    }

    private func answered(
        _ deviceID: String,
        accept: Bool,
        _ result: ActionResult,
        now: Date
    ) -> SyncTransition {
        // An answer for a prompt that is gone is the refusal of a cancelled
        // dial, and one for a prompt that has ended is the refusal that ended
        // it. Nobody is looking at either, and the ended prompt keeps saying
        // why it ended.
        guard let prompt, prompt.deviceID == deviceID, !prompt.isOver else {
            return SyncTransition(model: self)
        }
        switch result {
        case .answered(let document) where document.ok && accept:
            let done = withPrompt(nil).withNotice(Self.pairedNotice(prompt, now: now))
            // The pairing window closes on the first pairing that succeeds, as
            // it does on a Mac: it is the one moment a stranger can complete a
            // handshake, and nobody needs it open once the device they wanted
            // is paired.
            let closing: [SyncAction] =
                prompt.direction == .incoming && peers?.pairingPort != nil ? [.closePairingWindow] : []
            return SyncTransition(model: done.promotingWaiting(now: now), effects: closing)
        case .answered(let document) where document.ok:
            // Refused on purpose. The daemon adds a sentence only when the
            // other machine may have recorded this one anyway.
            let warning =
                document.detail == "refused" ? nil : SyncNotice.info(SyncText.sentence(document.detail))
            return SyncTransition(
                model: withPrompt(nil).withNotice(warning ?? notice).promotingWaiting(now: now))
        case .answered(let document):
            return SyncTransition(model: ended(SyncText.sentence(document.detail)))
        case .failed(let failure):
            return SyncTransition(model: ended(failure.message))
        case .opened, .proposed:
            return SyncTransition(model: self)
        }
    }

    private func ended(_ reason: String) -> SyncModel {
        withPrompt(prompt?.moved(to: .ended(reason)))
    }

    private static func pairedNotice(_ prompt: PairingPrompt, now: Date) -> SyncNotice {
        guard prompt.direction == .outgoing else {
            return .success("Paired with \(prompt.name).", now: now)
        }
        // The dialling side records the pairing as soon as its own person says
        // yes; the other machine may still be showing the code.
        return SyncNotice(
            tone: .success,
            message: "Paired with \(prompt.name).",
            detail: "If \(prompt.name) is still showing the code, confirm there too.",
            clearsAt: now + SyncNotice.successLifetime * 2
        )
    }

    // MARK: - Everything else

    private func pairingWindowChanged(_ result: ActionResult) -> SyncModel {
        switch result {
        case .opened(let window):
            return withPairingWindowEnding(window.expiresAt)
        case .answered(let document) where document.ok:
            return withPairingWindowEnding(nil)
        case .answered(let document):
            return withNotice(.problem(SyncFailure(message: SyncText.sentence(document.detail))))
        case .failed(let failure):
            return withNotice(.problem(failure))
        case .proposed:
            return self
        }
    }

    private func reported(_ action: SyncAction, _ result: ActionResult, now: Date) -> SyncModel {
        switch result {
        case .failed(let failure):
            return withNotice(.problem(failure))
        case .answered(let document) where !document.ok:
            let sentence = SyncText.sentence(document.detail)
            // "No peers are paired with this device" is an answer, not a fault.
            return withNotice(action == .syncNow ? .info(sentence) : .problem(SyncFailure(message: sentence)))
        case .answered(let document):
            // The switch already shows a live-push change; saying it again in
            // a banner is noise.
            guard case .setLivePush = action else {
                return withNotice(.success(SyncText.sentence(document.detail), now: now))
            }
            return self
        case .opened, .proposed:
            return self
        }
    }
}

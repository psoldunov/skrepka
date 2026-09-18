import Foundation
import SkrepkaIPC
import Testing

@testable import SkrepkaLinuxUI

/// Pairing from the Settings window, in both directions.
///
/// The property that matters most is the one a person never sees: no code is
/// ever dropped silently. A code on screen is answered, a dial cancelled while
/// it runs is refused the moment its code arrives, and a second device waits
/// rather than replacing the code somebody is halfway through comparing.
@Suite("Settings: pairing")
struct SyncModelPairingTests {
    typealias Fixture = SyncFixtures

    static let withDeckInSight = Fixture.model(Fixture.document([Fixture.nearby()]))

    @Test("dialling opens the prompt, and the proposal brings the code without losing the name")
    func dialThenCompare() {
        let dialling = Self.withDeckInSight.sending(.pair(deviceID: Fixture.deckID))
        #expect(dialling.prompt?.stage == .dialling)
        #expect(dialling.prompt?.name == "Deck")

        // The dialling side's proposal carries no name.
        let proposal = Fixture.proposal(name: nil, direction: PairingProposalDocument.Direction.outgoing)
        let comparing = dialling.applying(
            .finished(.pair(deviceID: Fixture.deckID), .proposed(proposal), refreshed: nil), now: Fixture.now)
        #expect(comparing.effects.isEmpty)
        #expect(comparing.model.prompt?.stage == .comparing)
        #expect(comparing.model.prompt?.code == "A3F2-91BC-D4E7-0182")
        #expect(comparing.model.prompt?.name == "Deck")
    }

    @Test("a dial cancelled while it runs is refused as soon as its code arrives")
    func cancelledDialIsRefused() {
        let cancelled = Self.withDeckInSight.sending(.pair(deviceID: Fixture.deckID)).cancellingPrompt(
            now: Fixture.now)
        #expect(cancelled.model.prompt == nil)
        #expect(cancelled.effects.isEmpty)

        let proposal = Fixture.proposal(direction: PairingProposalDocument.Direction.outgoing)
        let arrived = cancelled.model.applying(
            .finished(.pair(deviceID: Fixture.deckID), .proposed(proposal), refreshed: nil), now: Fixture.now)
        #expect(arrived.effects == [.answer(deviceID: Fixture.deckID, accept: false)])
    }

    @Test("a dial that fails ends the prompt with the daemon's reason")
    func failedDial() {
        let failure = SyncFailure(message: "\"CDCDCDCD\" is not accepting new pairings.")
        let ended = Self.withDeckInSight.sending(.pair(deviceID: Fixture.deckID)).applying(
            .finished(.pair(deviceID: Fixture.deckID), .failed(failure), refreshed: nil), now: Fixture.now
        ).model
        #expect(ended.prompt?.stage == .ended(failure.message))
        #expect(ended.cancellingPrompt(now: Fixture.now).model.prompt == nil)
    }

    @Test("a code on screen is answered no when the prompt is closed, not dropped")
    func closingAnswersNo() {
        let asked = Self.withDeckInSight.applying(.pairingRequested(Fixture.proposal()), now: Fixture.now)
            .model
        let closing = asked.cancellingPrompt(now: Fixture.now)
        #expect(closing.effects == [.answer(deviceID: Fixture.deckID, accept: false)])
        #expect(closing.model.prompt == asked.prompt)
    }

    @Test("accepting a device that dialled in closes the pairing window behind it")
    func incomingAcceptedClosesTheWindow() {
        let open = Fixture.model(Fixture.document([Fixture.nearby()], pairingPort: 5555))
        let answering = open.applying(.pairingRequested(Fixture.proposal()), now: Fixture.now).model
            .sending(.answer(deviceID: Fixture.deckID, accept: true))
        #expect(answering.prompt?.stage == .answering(accept: true))

        let done = answering.applying(
            .finished(
                .answer(deviceID: Fixture.deckID, accept: true),
                .answered(.succeeded("paired", subject: Fixture.deckID)),
                refreshed: Fixture.document([Fixture.paired(Fixture.deckID, name: "Deck")], pairingPort: 5555)
            ),
            now: Fixture.now
        )
        #expect(done.model.prompt == nil)
        #expect(done.model.notice?.message == "Paired with Deck.")
        #expect(done.effects == [.closePairingWindow])
    }

    @Test("an outgoing refusal that may leave the other side paired says so")
    func oneSidedRefusalIsReported() {
        let comparing = Self.withDeckInSight.sending(.pair(deviceID: Fixture.deckID)).applying(
            .finished(
                .pair(deviceID: Fixture.deckID),
                .proposed(Fixture.proposal(direction: PairingProposalDocument.Direction.outgoing)),
                refreshed: nil
            ),
            now: Fixture.now
        ).model
        let refused = comparing.sending(.answer(deviceID: Fixture.deckID, accept: false)).applying(
            .finished(
                .answer(deviceID: Fixture.deckID, accept: false),
                .answered(.succeeded("refused. That device may now list this one as paired")),
                refreshed: nil
            ),
            now: Fixture.now
        ).model
        #expect(refused.prompt == nil)
        #expect(refused.notice?.tone == .info)
        #expect(refused.notice?.message.hasPrefix("Refused. That device") == true)
    }

    @Test("a second device waits its turn, and gets it when the first is done")
    func secondDeviceWaits() {
        let two = Fixture.model(
            Fixture.document([Fixture.nearby(), Fixture.nearby(Fixture.laptopID, name: "Laptop")])
        )
        .applying(.pairingRequested(Fixture.proposal()), now: Fixture.now).model
        .applying(.pairingRequested(Fixture.proposal(Fixture.laptopID, name: "Laptop")), now: Fixture.now)
        .model
        #expect(two.prompt?.deviceID == Fixture.deckID)
        #expect(two.waiting.map(\.deviceID) == [Fixture.laptopID])

        let refusedFirst = SyncEvent.finished(
            .answer(deviceID: Fixture.deckID, accept: false),
            .answered(.succeeded(ActionDocument.refusedDetail)),
            refreshed: nil
        )
        let next = two.sending(.answer(deviceID: Fixture.deckID, accept: false))
            .applying(refusedFirst, now: Fixture.now).model
        #expect(next.prompt?.deviceID == Fixture.laptopID)
        #expect(next.waiting.isEmpty)
        #expect(next.notice == nil)
    }

    @Test("the same device dialling again replaces its own prompt")
    func sameDeviceReplaces() {
        let first = Self.withDeckInSight.applying(
            .pairingRequested(Fixture.proposal(expiresIn: 30)), now: Fixture.now
        ).model
        let again = first.applying(.pairingRequested(Fixture.proposal(expiresIn: 120)), now: Fixture.now)
            .model
        #expect(again.prompt?.expiresAt == Fixture.now + 120)
        #expect(again.waiting.isEmpty)
    }

    @Test("a code nobody confirms runs out, and so do the devices waiting behind it")
    func codesRunOut() {
        let asked = Self.withDeckInSight
            .applying(.pairingRequested(Fixture.proposal(expiresIn: 60)), now: Fixture.now).model
            .applying(.pairingRequested(Fixture.proposal(Fixture.laptopID, expiresIn: 30)), now: Fixture.now)
            .model
        let later = asked.expiring(now: Fixture.now + 90)
        #expect(later.prompt?.stage == .ended(PairingPrompt.tookTooLong))
        #expect(later.waiting.isEmpty)
    }

    /// The daemon keeps one proposal per device and answers whichever it holds,
    /// so with both directions in flight nobody can know which code a "yes"
    /// confirms — the one case where showing a code would be wrong.
    @Test("dials that cross end the prompt and refuse both, never answering a code nobody compared")
    func crossedDials() {
        let dialling = Self.withDeckInSight.sending(.pair(deviceID: Fixture.deckID))
        let crossed = dialling.applying(.pairingRequested(Fixture.proposal()), now: Fixture.now)
        #expect(crossed.model.prompt?.stage == .ended(PairingPrompt.crossed))
        #expect(crossed.effects == [.answer(deviceID: Fixture.deckID, accept: false)])

        let late = crossed.model.applying(
            .finished(
                .pair(deviceID: Fixture.deckID),
                .proposed(Fixture.proposal(direction: PairingProposalDocument.Direction.outgoing)),
                refreshed: nil
            ),
            now: Fixture.now
        )
        #expect(late.effects == [.answer(deviceID: Fixture.deckID, accept: false)])

        let answered = late.model.applying(
            .finished(
                .answer(deviceID: Fixture.deckID, accept: false),
                .answered(.refused("no pairing is waiting for that device")),
                refreshed: nil
            ),
            now: Fixture.now
        )
        #expect(answered.model.prompt?.stage == .ended(PairingPrompt.crossed))
    }

    @Test("a device re-dialling while the answer is on its way is left to that answer")
    func redialWhileAnswering() {
        let answering = Self.withDeckInSight.applying(.pairingRequested(Fixture.proposal()), now: Fixture.now)
            .model
            .sending(.answer(deviceID: Fixture.deckID, accept: true))
        let again = answering.applying(.pairingRequested(Fixture.proposal(expiresIn: 90)), now: Fixture.now)
        #expect(again.model.prompt == answering.prompt)
        #expect(again.model.waiting.isEmpty)
        #expect(again.effects.isEmpty)
    }

    @Test("an outgoing proposal on the signal is ignored — it answers a dial, not a request")
    func outgoingSignalIgnored() {
        let model = Self.withDeckInSight.applying(
            .pairingRequested(Fixture.proposal(direction: PairingProposalDocument.Direction.outgoing)),
            now: Fixture.now
        ).model
        #expect(model.prompt == nil)
    }
}

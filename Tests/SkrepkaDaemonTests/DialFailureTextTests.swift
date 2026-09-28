import Foundation
import NIOCore
import SkrepkaSync
import Testing

@testable import SkrepkaDaemon

/// What Linux says when one of its own dials does not reach the peer.
@Suite("Dial failure text")
struct DialFailureTextTests {
    /// The link state used to read "failed: Connect timeout (10 s)".
    @Test("A link that gets no answer says so, and why that usually is")
    func linkReasonNamesTheFirewall() {
        let reason = DialFailure.linkReason(for: ChannelError.connectTimeout(.seconds(10)))
        #expect(reason.hasPrefix("no answer"))
        #expect(reason.contains("firewall"))
    }

    /// A TLS or protocol refusal already has a precise description; replacing
    /// it with a guess about firewalls would hide an identity that changed.
    @Test("A failure after the connect keeps its own description")
    func otherFailuresKeepTheirWords() {
        let error = SyncTLSError.handshakeTimedOut
        #expect(DialFailure.linkReason(for: error) == String(describing: error))
    }

    @Test("A dial to pair that got no answer names the port it dialled")
    func pairingSentenceNamesThePort() {
        let error = PairError.couldNotReach("32c1c527", .noAnswer, port: 27183)
        #expect(error.description.contains("\"32c1c527\" did not answer on TCP port 27183"))
        #expect(error.description.contains("skrepka doctor"))

        let refused = PairError.couldNotReach("32c1c527", .refused, port: 27183)
        #expect(refused.description.contains("pairing window may have just closed"))
    }
}

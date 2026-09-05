#if canImport(Network) && canImport(dnssd)

    import Foundation
    import Testing
    import dnssd

    @testable import SkrepkaSync

    /// The one bit that separates a registration going in from one coming back
    /// out.
    ///
    /// `DNSServiceRegisterReply` fires more than once, and both callbacks carry
    /// `kDNSServiceErr_NoError` when the responder simply took the record away
    /// again — dns_sd.h:1275-1284. Read the error code alone and a withdrawn
    /// advertisement reads as a successful one, which is a Mac that is off the
    /// network while the app says it is published.
    @Suite("Bonjour registration reply")
    struct BonjourRegistrationReplyTests {
        static func reply(
            flags: DNSServiceFlags,
            errorCode: DNSServiceErrorType = DNSServiceErrorType(kDNSServiceErr_NoError)
        ) -> BonjourDiscovery.RegistrationReply {
            BonjourDiscovery.RegistrationReply(
                flags: flags,
                errorCode: errorCode,
                name: "mac",
                serviceType: "_skrepka._tcp.",
                domain: "local."
            )
        }

        @Test("Add set is a registration; Add clear is a deregistration")
        func addFlagSeparatesTheTwoCallbacks() {
            #expect(Self.reply(flags: DNSServiceFlags(kDNSServiceFlagsAdd)).isAdd)
            #expect(Self.reply(flags: 0).isAdd == false)
        }

        /// dns_sd.h:226-232: "code that tests `if (flags == kDNSServiceFlagsAdd)`
        /// will fail if, in a future release, another bit in the 32-bit flags
        /// field is also set. The reliable way to test whether a particular bit
        /// is set is not with an equality test, but with a bitwise mask."
        @Test("The Add bit is read as a bit, not compared to the whole field")
        func addIsATestOfOneBit() {
            let withAnotherBit =
                DNSServiceFlags(kDNSServiceFlagsAdd) | DNSServiceFlags(kDNSServiceFlagsDefault)
            #expect(Self.reply(flags: withAnotherBit).isAdd)
        }

        /// The error code stays the first thing checked: dns_sd.h says the other
        /// parameters are undefined when it is non-zero, so a responder that
        /// died is a loss whatever the flags say.
        @Test("A responder that stopped running is a loss even with Add set")
        func serviceNotRunningIsALoss() {
            let reply = Self.reply(
                flags: DNSServiceFlags(kDNSServiceFlagsAdd),
                errorCode: BonjourDiscovery.Status.serviceNotRunning
            )
            #expect(reply.isAdd)
            #expect(reply.errorCode != BonjourDiscovery.Status.noError)
            #expect(
                BonjourDiscovery.message(for: reply.errorCode) == "mDNSResponder is not running")
        }
    }

#endif

#if canImport(Network) && canImport(dnssd)

    import Foundation
    import Testing
    import dnssd

    @testable import SkrepkaSync

    /// Telling "macOS has not let this app onto the local network" apart from
    /// "the thing you asked for went wrong".
    ///
    /// macOS 15 and later refuse every Bonjour operation with
    /// `kDNSServiceErr_PolicyDenied` (-65570) until the user has granted the
    /// Local Network privilege — and, per TN3179, refuse it *immediately*, while
    /// the system's own alert is still on screen and unanswered. Folded into
    /// `advertisingFailed` or `resolutionFailed` it reads to the user as a broken
    /// network or an absent peer, and the one thing that would fix it — a switch
    /// in System Settings — is the one thing they are not told about.
    @Suite("Local network denial")
    struct LocalNetworkDenialTests {
        private static let policyDenied = DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
        private static let nameConflict = DNSServiceErrorType(kDNSServiceErr_NameConflict)

        private static let peer = DiscoveredPeer(
            instanceName: "laptop",
            serviceType: ServiceDescriptor.serviceType,
            domain: "local.",
            interfaceIndex: nil,
            advertisement: .unread
        )

        @Test("A registration macOS refused is named as a permission, not a failure")
        func advertisingPolicyDenialIsNamed() {
            #expect(BonjourDiscovery.advertisingError(Self.policyDenied) == .localNetworkDenied)
        }

        @Test("Every other registration status is still an advertising failure")
        func otherAdvertisingStatusesAreUnchanged() {
            #expect(
                BonjourDiscovery.advertisingError(Self.nameConflict)
                    == .advertisingFailed(reason: "the service name is already taken")
            )
        }

        /// Resolving is a Bonjour operation too, and it is the one that runs per
        /// peer: reported as this peer failing, a refused privilege looks like
        /// every peer on the network having gone away at once.
        @Test("A resolve macOS refused is not blamed on the peer")
        func resolutionPolicyDenialIsNamed() {
            #expect(
                BonjourDiscovery.resolutionError(Self.policyDenied, peer: Self.peer)
                    == .localNetworkDenied
            )
        }

        @Test("Every other resolve status still names the peer")
        func otherResolutionStatusesAreUnchanged() {
            #expect(
                BonjourDiscovery.resolutionError(Self.nameConflict, peer: Self.peer)
                    == .resolutionFailed(peer: "laptop", reason: "the service name is already taken")
            )
        }
    }

#endif

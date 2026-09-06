import Foundation
import Testing

@testable import SkrepkaSync

/// The one rule that makes design §3 enforceable rather than aspirational.
@Suite("Peer platform")
struct PeerPlatformTests {
    /// Never between two Apple devices — Universal Clipboard already does that,
    /// and two systems owning one pasteboard race non-deterministically. On for
    /// macOS↔Linux, which is the gap Apple leaves. Off for `unknown`, because
    /// an unrecognised platform is likelier a future Apple device than a future
    /// Linux one, and a feature the user has to switch on beats a pasteboard
    /// collision the user cannot diagnose.
    @Test("Live push defaults off between Apple peers and on across platforms")
    func livePushDefaultsOffBetweenApplePeers() {
        #expect(!PeerPlatform.livePushDefaultsOn(local: .macos, remote: .macos))

        #expect(PeerPlatform.livePushDefaultsOn(local: .macos, remote: .linux))
        #expect(PeerPlatform.livePushDefaultsOn(local: .linux, remote: .macos))
        // Two Linux peers have no Universal Clipboard to collide with.
        #expect(PeerPlatform.livePushDefaultsOn(local: .linux, remote: .linux))

        for platform in PeerPlatform.allCases {
            #expect(!PeerPlatform.livePushDefaultsOn(local: .unknown, remote: platform))
            #expect(!PeerPlatform.livePushDefaultsOn(local: platform, remote: .unknown))
        }
    }

    /// The default is symmetric, so two peers reach the same conclusion without
    /// negotiating it.
    @Test("The default does not depend on which peer asks")
    func livePushDefaultIsSymmetric() {
        for local in PeerPlatform.allCases {
            for remote in PeerPlatform.allCases {
                #expect(
                    PeerPlatform.livePushDefaultsOn(local: local, remote: remote)
                        == PeerPlatform.livePushDefaultsOn(local: remote, remote: local)
                )
            }
        }
    }

    /// A peer advertising a platform added after this build shipped is still a
    /// peer worth talking to; it just does not get live push by default.
    @Test("An unrecognised platform decodes as unknown rather than failing")
    func unrecognisedPlatformsDecodeAsUnknown() {
        #expect(PeerPlatform(wireValue: "macos") == .macos)
        #expect(PeerPlatform(wireValue: "linux") == .linux)
        #expect(PeerPlatform(wireValue: "visionos") == .unknown)
        #expect(PeerPlatform(wireValue: "") == .unknown)
        #expect(PeerPlatform(wireValue: "MACOS") == .unknown)
    }
}

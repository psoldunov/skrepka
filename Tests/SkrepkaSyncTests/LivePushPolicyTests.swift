import Foundation
import Testing

@testable import SkrepkaSync

/// Design §3's rule, the per-peer override that can beat it, and the two things
/// that stop a push looping or leaking.
///
/// These are the assertions the phase document asks for as
/// `SyncCoordinatorTests.livePushOffForApplePeers` and
/// `livePushSuppressesEcho`. They live here rather than against the coordinator
/// because the decisions themselves were put here — the coordinator holds a
/// socket and a settings pane, and a rule that only exists inside it is a rule
/// the Linux daemon will have to write a second time.
@Suite("Live push policy")
struct LivePushPolicyTests {
    // MARK: - The platform rule

    @Test("Live push is off between two Apple devices, and says why")
    func offBetweenAppleDevices() {
        let setting = LivePushSetting(local: .macos, remote: .macos)
        #expect(!setting.isOn)
        #expect(setting.reason == .offBetweenAppleDevices)
        #expect(!setting.isOverridden)
    }

    @Test("Live push is on across platforms")
    func onAcrossPlatforms() {
        #expect(LivePushSetting(local: .macos, remote: .linux).isOn)
        #expect(LivePushSetting(local: .linux, remote: .macos).isOn)
        #expect(LivePushSetting(local: .linux, remote: .linux).isOn)
    }

    /// An unrecognised platform is more likely a future Apple device than a
    /// future Linux one, so guessing wrong costs a switch the user has to find
    /// rather than a pasteboard collision they cannot diagnose.
    @Test("An unrecognised platform defaults live push off, in either position")
    func offForUnrecognisedPlatform() {
        for pair in [(PeerPlatform.macos, PeerPlatform.unknown), (.unknown, .linux)] {
            let setting = LivePushSetting(local: pair.0, remote: pair.1)
            #expect(!setting.isOn)
            #expect(setting.reason == .offForUnrecognisedPlatform)
        }
    }

    /// The boolean the rest of the code already used and the reason a settings
    /// row shows have to be one rule, or a switch drawn off will one day carry
    /// an explanation for being on.
    @Test("The platform default and the reason cannot disagree")
    func theBooleanAndTheReasonAgree() {
        for local in PeerPlatform.allCases {
            for remote in PeerPlatform.allCases {
                #expect(
                    PeerPlatform.livePushDefaultsOn(local: local, remote: remote)
                        == LivePushDefault.between(local: local, remote: remote).isOn
                )
            }
        }
    }

    // MARK: - The override

    @Test("The user's choice beats the platform default in both directions")
    func theChoiceBeatsTheDefault() {
        let onDespiteApple = LivePushSetting(local: .macos, remote: .macos, choice: .on)
        #expect(onDespiteApple.isOn)
        #expect(onDespiteApple.isOverridden)
        // The reason survives the override, so a row can still explain what the
        // user is departing from.
        #expect(onDespiteApple.reason == .offBetweenAppleDevices)

        let offDespiteLinux = LivePushSetting(local: .macos, remote: .linux, choice: .off)
        #expect(!offDespiteLinux.isOn)
        #expect(offDespiteLinux.isOverridden)
    }

    @Test("A choice round trips through the value a store writes")
    func choiceRoundTrips() {
        for choice in LivePushChoice.allCases {
            #expect(LivePushChoice(storedValue: choice.storedValue) == choice)
        }
        // "Nothing recorded" is a missing column rather than a stored word, so a
        // store never has to know a third spelling of the default.
        #expect(LivePushChoice.followsPlatformDefault.storedValue == nil)
        // A value written by a newer build falls back to the default rather than
        // failing the peer.
        #expect(LivePushChoice(storedValue: "sometimes") == .followsPlatformDefault)
    }

    // MARK: - The gate

    @Test("Concealed content is never pushed")
    func concealedContentIsNeverPushed() {
        #expect(
            !LivePushGate.isPushable(
                contentHash: "abc",
                isConcealed: true,
                recentlyReceived: RecentHashes(),
                at: Date()
            )
        )
    }

    /// The phase's `livePushSuppressesEcho`, asserted over the hash set rather
    /// than the pause window — the window is a race this cannot observe, and the
    /// set is the guard that exists for when the window is missed.
    @Test("A hash just accepted from a peer is not pushed back")
    func aReceivedHashIsNotRebroadcast() {
        let now = Date()
        var received = RecentHashes()
        received.remember("from-the-peer", at: now)

        #expect(
            !LivePushGate.isPushable(
                contentHash: "from-the-peer",
                isConcealed: false,
                recentlyReceived: received,
                at: now
            )
        )
        // Something else copied in the same moment is unaffected: the guard is
        // about one clipping, not about a quiet period.
        #expect(
            LivePushGate.isPushable(
                contentHash: "typed-here",
                isConcealed: false,
                recentlyReceived: received,
                at: now
            )
        )
    }

    @Test("Suppression lapses, so a deliberate re-copy still syncs")
    func suppressionLapses() {
        let now = Date()
        var received = RecentHashes()
        received.remember("shared", at: now)
        let later = now.addingTimeInterval(RecentHashes.defaultLifetime + 1)

        #expect(
            LivePushGate.isPushable(
                contentHash: "shared",
                isConcealed: false,
                recentlyReceived: received,
                at: later
            )
        )
    }
}

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
        var gate = LivePushGate()
        let admitted = gate.admitCopy("abc", isConcealed: true, at: Date())
        #expect(!admitted)
    }

    /// The phase's `livePushSuppressesEcho`, asserted over the gate rather than
    /// the pause window — the window is a race this cannot observe, and the
    /// gate is the guard that exists for when the window is missed.
    @Test("A hash just accepted from a peer is not pushed back")
    func aReceivedHashIsNotRebroadcast() {
        let now = Date()
        var gate = LivePushGate()
        gate.noteReceived("from-the-peer", at: now)

        let admitted = gate.admitCopy("from-the-peer", isConcealed: false, at: now)
        #expect(!admitted)
    }

    /// Something else copied in the same moment is unaffected: the guard is
    /// about one clipping, not about a quiet period.
    @Test("Something else copied beside a push is pushed")
    func somethingElseIsPushed() {
        let now = Date()
        var gate = LivePushGate()
        gate.noteReceived("from-the-peer", at: now)

        let admitted = gate.admitCopy("typed-here", isConcealed: false, at: now)
        #expect(admitted)
    }

    /// The hash window alone lapses after thirty seconds. That was the whole
    /// guard once, and it let through any echo slower than that — a pasteboard
    /// relayed by Universal Clipboard, a Linux compositor echoing a write back.
    /// The hand-over is what holds past it.
    @Test("A handed-over hash stays suppressed past the window while nothing else is copied")
    func handoffOutlivesTheWindow() {
        let now = Date()
        var gate = LivePushGate()
        gate.noteReceived("shared", at: now)

        let echo = gate.admitCopy("shared", isConcealed: false, at: later(than: now))
        #expect(!echo)
        // Its own echo, heard twice, does not end the hand-over either.
        let secondEcho = gate.admitCopy("shared", isConcealed: false, at: later(than: now))
        #expect(!secondEcho)
    }

    /// Copying anything else ends the hand-over, so the old content copied
    /// again afterwards is a copy the user made and goes out like one.
    @Test("A re-copy after another copy is pushed")
    func aRecopyAfterAnotherCopyIsPushed() {
        let now = Date()
        var gate = LivePushGate()
        gate.noteReceived("shared", at: now)

        let other = gate.admitCopy("typed-here", isConcealed: false, at: later(than: now))
        let recopy = gate.admitCopy("shared", isConcealed: false, at: later(than: now))
        #expect(other)
        #expect(recopy)
    }

    /// A password copied after a push is a copy even though nothing records
    /// it: the clipboard no longer holds what the peer sent.
    @Test("A copy the capture rules refused ends the hand-over")
    func aRefusedCopyEndsTheHandoff() {
        let now = Date()
        var gate = LivePushGate()
        gate.noteReceived("shared", at: now)

        gate.noteUnrecordedCopy()
        let recopy = gate.admitCopy("shared", isConcealed: false, at: later(than: now))
        #expect(recopy)
    }

    /// The handed-over content coming back and failing to store is still the
    /// hand-over coming back, not the user moving on.
    @Test("The handed-over content going unrecorded keeps the hand-over")
    func theHandoffUnrecordedKeepsIt() {
        let now = Date()
        var gate = LivePushGate()
        gate.noteReceived("shared", at: now)

        gate.noteUnrecordedCopy("shared")
        let echo = gate.admitCopy("shared", isConcealed: false, at: later(than: now))
        #expect(!echo)
    }

    /// The hash window still stands behind the hand-over: a burst of pushes
    /// replaces the hand-over with the newest, and the older ones are covered
    /// only by the window.
    @Test("An older push in a burst is still suppressed by the window")
    func theWindowBacksUpABurst() {
        let now = Date()
        var gate = LivePushGate()
        gate.noteReceived("first", at: now)
        gate.noteReceived("second", at: now)

        let older = gate.admitCopy("first", isConcealed: false, at: now)
        #expect(!older)
    }

    /// Past the thirty-second window the gate keeps only the hand-over.
    private func later(than now: Date) -> Date {
        now.addingTimeInterval(RecentHashes.defaultLifetime + 1)
    }
}

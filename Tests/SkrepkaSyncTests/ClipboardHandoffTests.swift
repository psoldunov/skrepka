import Foundation
import Testing

@testable import SkrepkaSync

/// The hand-over memory: which content a peer last put on this device's
/// clipboard, for exactly as long as it is still what the clipboard holds.
@Suite("Clipboard handoff")
struct ClipboardHandoffTests {
    @Test("Nothing is handed over before a peer pushes anything")
    func startsEmpty() {
        #expect(!ClipboardHandoff().isHandedOver("anything"))
    }

    @Test("A received push is handed over, and nothing else is")
    func receivedIsHandedOver() {
        var handoff = ClipboardHandoff()
        handoff.received("from-the-peer")
        #expect(handoff.isHandedOver("from-the-peer"))
        #expect(!handoff.isHandedOver("typed-here"))
    }

    /// The echo of the write itself: capturing what was handed over is not the
    /// user copying something new, so it must not end the hand-over.
    @Test("Capturing the handed-over content keeps it handed over")
    func capturingTheSameKeepsIt() {
        var handoff = ClipboardHandoff()
        handoff.received("from-the-peer")
        handoff.captured("from-the-peer")
        #expect(handoff.isHandedOver("from-the-peer"))
    }

    @Test("Capturing anything else ends the hand-over for good")
    func capturingSomethingElseEndsIt() {
        var handoff = ClipboardHandoff()
        handoff.received("from-the-peer")
        handoff.captured("typed-here")
        #expect(!handoff.isHandedOver("from-the-peer"))
        #expect(!handoff.isHandedOver("typed-here"))

        // A deliberate re-copy of the old content is now a copy like any other.
        handoff.captured("from-the-peer")
        #expect(!handoff.isHandedOver("from-the-peer"))
    }

    /// A copy refused before it was hashed — a password, an excluded app —
    /// still replaced what the clipboard held.
    @Test("A copy with no hash ends the hand-over")
    func aCopyWithNoHashEndsIt() {
        var handoff = ClipboardHandoff()
        handoff.received("from-the-peer")
        handoff.captured(nil)
        #expect(!handoff.isHandedOver("from-the-peer"))
    }

    /// A second push replaces the first: the clipboard holds one thing, and it
    /// is the newer one.
    @Test("A newer push replaces the one before it")
    func newerPushReplaces() {
        var handoff = ClipboardHandoff()
        handoff.received("first")
        handoff.received("second")
        #expect(!handoff.isHandedOver("first"))
        #expect(handoff.isHandedOver("second"))
    }
}

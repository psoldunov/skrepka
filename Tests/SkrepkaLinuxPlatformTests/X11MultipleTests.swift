import CX11
import Foundation
import Testing

@testable import SkrepkaLinuxPlatform

/// The `MULTIPLE` target, against the real owner.
///
/// Split from ``X11BackendTests`` because it needs a third party neither of
/// those tests has: ``XMultipleRequestor``, a direct Xlib client. `xclip`
/// converts one target per invocation and never issues a `MULTIPLE`, so
/// `advertisesRequiredTargets` can only prove the atom is *listed*. The
/// pair-rewriting in ``XClipboardSession``'s handler — the part with behaviour
/// in it — needs a requestor that asks.
@Suite("X11 MULTIPLE", .serialized, .enabled(if: HeadlessSession.isAvailable(.xvfb)))
struct X11MultipleTests {
    /// ICCCM §2.6.2: "if the owner fails to convert the target named by an atom
    /// in the MULTIPLE property, it should replace that atom in the property
    /// with None." Both halves are asserted — the conversion that worked put
    /// its bytes where it was told, and the one that could not was marked as
    /// refused rather than silently left pointing at an empty property.
    @Test("an unservable pair in a MULTIPLE request comes back as None")
    func rewritesUnservablePairToNone() async throws {
        let session = try HeadlessSession(.xvfb, label: "multiple")
        try session.start()

        guard let displayName = session.x11Display else {
            session.stop()
            Issue.record("Xvfb produced no display name")
            return
        }
        let reader = XFixesReader(displayName: displayName)
        do {
            try await reader.start()
        } catch {
            session.stop()
            throw error
        }

        do {
            try await assertMultiple(on: reader, session: session, displayName: displayName)
            await reader.stop()
            session.stop()
        } catch {
            await reader.stop()
            session.stop()
            throw error
        }
    }

    /// The body of the test, split out so neither half carries both the
    /// lifecycle and the assertions.
    private func assertMultiple(
        on reader: XFixesReader,
        session: HeadlessSession,
        displayName: String
    ) async throws {
        let payload = Data("multiple works".utf8)
        await reader.setSelection(["UTF8_STRING": payload])
        // The set is queued for the session's own loop, so ownership is not
        // instant. `xclip` asking and getting the bytes back is the same signal
        // every other owner test waits on.
        try #require(await waitForOwnership(of: "multiple works", using: session))

        let requestor = try XMultipleRequestor(displayName: displayName)
        let outcome = try requestor.requestMultiple(
            servedTarget: requestor.atom(named: "UTF8_STRING"),
            unservableTarget: requestor.atom(named: XMultipleRequestor.unservableTargetName)
        )

        // A `MULTIPLE` that partly succeeded is still answered with the request
        // property, not with None — the refusal is per pair.
        #expect(outcome.repliedProperty != X11.none)
        #expect(outcome.pairs.count == 4)
        // The served pair kept its destination, and the bytes are there.
        #expect(outcome.servedPropertyAtom == requestor.servedProperty)
        #expect(outcome.servedBytes == payload)
        // The pair Skrepka cannot convert was rewritten. This is the point.
        #expect(outcome.unservedPropertyAtom == X11.none)
        #expect(outcome.unservedPropertyAtom != requestor.unservedProperty)
    }

    /// Waits until `xclip` can read the selection back, which is how the other
    /// owner tests establish that the loop has actually taken ownership.
    private func waitForOwnership(
        of text: String,
        using session: HeadlessSession,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if session.paste() == text { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}

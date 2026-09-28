import Testing

@testable import SkrepkaLinuxUI

/// What the shortcut session does with each portal answer.
///
/// The case that matters most is KDE's: xdg-desktop-portal-kde 6.4 answers a
/// successful `BindShortcuts` with empty results — seen against SteamOS 3.8's
/// own packages — and a client that reads that as "not bound" reports a working
/// shortcut as broken.
@Suite("Global shortcut: session steps")
struct ShortcutStepTests {
    private typealias Answer = Result<PortalResponse, DBusError>

    private static func answer(code: UInt32 = 0, shortcuts: [(String, String?)]?) -> Answer {
        guard let shortcuts else { return .success(PortalResponse(code: code, results: [:])) }
        let values = shortcuts.map { identifier, trigger in
            DBusValue.tuple([
                .string(identifier),
                .dictionary(trigger.map { ["trigger_description": .string($0)] } ?? [:]),
            ])
        }
        let list = DBusValue.array(elementSignature: "(sa{sv})", values: values)
        return .success(PortalResponse(code: code, results: ["shortcuts": list]))
    }

    @Test("an empty answer to a successful bind asks what is bound")
    func kdeEmptyBindAnswer() {
        #expect(ShortcutStep.afterBinding(Self.answer(shortcuts: nil)) == .list)
        #expect(ShortcutStep.afterBinding(Self.answer(shortcuts: [])) == .list)
    }

    @Test("a bind that names the shortcut is bound, with the desktop's words")
    func bindNamingTheShortcut() {
        let answer = Self.answer(shortcuts: [("show-picker", "Meta+Shift+V")])
        #expect(ShortcutStep.afterBinding(answer) == .bound("Meta+Shift+V"))
    }

    @Test("a bind the user cancelled is not bound, and says so")
    func cancelledBind() {
        let step = ShortcutStep.afterBinding(Self.answer(code: 1, shortcuts: nil))
        #expect(step == .unbound(PortalResponse.describe(code: 1)))
    }

    /// KDE's portal lists a saved trigger on a fresh session but hands it to
    /// kglobalaccel only on a bind, so a session that listed first and saw it
    /// bound left the shortcut dead on every login after the first.
    @Test("a new session binds before it lists anything")
    func sessionOpensWithABind() {
        #expect(ShortcutStep.opening == .bind)
    }

    @Test("a confirming listing without the shortcut reports it unbound, not a second bind")
    func listingWithoutTheShortcut() {
        let other = Self.answer(shortcuts: [("something-else", "Ctrl+X")])
        #expect(ShortcutStep.afterListing(other) == .unbound(ShortcutStep.noKey))
    }

    @Test("a failed confirming listing reports why")
    func failedListing() {
        let failure: Answer = .failure(DBusError(name: nil, message: "boom"))
        #expect(ShortcutStep.afterListing(failure) == .unbound("boom"))
    }

    @Test("a listing with the shortcut is bound")
    func listingWithTheShortcut() {
        let listed = Self.answer(shortcuts: [("show-picker", nil)])
        #expect(ShortcutStep.afterListing(listed) == .bound(GlobalShortcutTrigger.showPicker))
    }
}

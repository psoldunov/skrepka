import SkrepkaCore

/// What a key press means to the picker.
///
/// The whole keyboard contract in one value, decided without GTK in scope. The
/// window translates a `key-pressed` signal into one of these and does what it
/// says; nothing about the decision needs a display, so all of it is tested.
public enum PickerCommand: Equatable, Sendable {
    case dismiss
    /// Rows to move, signed. Clamping belongs to whoever holds the results.
    case moveSelection(by: Int)
    case selectFirst
    case selectLast
    case choose(PasteStyle)
    /// Alt+1–9, which chooses that row outright.
    case chooseRow(index: Int)
    case togglePin
    /// Not the picker's key. It goes to the search field, which is what makes
    /// the first keystroke after the hotkey land where the user expects.
    case type
}

/// Turns a key press into a ``PickerCommand``.
///
/// A transcription of `Sources/Skrepka/Picker/PickerView.swift`'s `handle(keyPress:)`
/// rather than a second design — the Linux picker should be recognisably the
/// same product, and a shortcut that exists on one platform and not the other
/// is a bug report waiting to happen.
///
/// The one deliberate difference is the modifier. macOS uses ⌘; Linux uses
/// **Alt**, not Ctrl, and that is a convention decision rather than a
/// translation:
///
///   - Ctrl+1–9 switches tabs in every browser and terminal on the platform,
///     and Ctrl+P prints. Users arrive with those bound.
///   - Alt+1–9 is what Linux launchers already use to pick the nth row — rofi
///     and its imitators — so it is the gesture this audience has.
///
/// The palette holds exclusive keyboard focus while it is open, so nothing
/// underneath can see these keys and there is no conflict to resolve at the
/// window-manager level. The choice is about muscle memory, which is why it is
/// worth writing down.
public enum PickerKeyMap {
    /// - Parameter keycode: the hardware key, which is the same number on every
    ///   keyboard layout. Only Alt+1–9 reads it — see
    ///   ``rowIndex(keysym:keycode:)``. Pass 0 when there is none.
    /// - Parameter pageJump: rows a Page Up or Page Down moves. The macOS
    ///   picker takes this from its own metrics, so it is a parameter rather
    ///   than a constant here.
    public static func command(
        keysym: UInt32,
        keycode: UInt32,
        modifiers: PickerModifiers,
        pageJump: Int
    ) -> PickerCommand {
        if modifiers.contains(.alt) {
            return altCommand(keysym: keysym, keycode: keycode, modifiers: modifiers)
        }
        if let offset = moveOffset(for: keysym, pageJump: pageJump) {
            return .moveSelection(by: offset)
        }
        switch keysym {
        case Keysym.escape: return .dismiss
        case Keysym.home: return .selectFirst
        case Keysym.end: return .selectLast
        case Keysym.enter, Keysym.keypadEnter: return .choose(.rich)
        default: return .type
        }
    }

    /// Rows to move for a navigation key, or `nil` if it is not one.
    private static func moveOffset(for keysym: UInt32, pageJump: Int) -> Int? {
        switch keysym {
        case Keysym.up: -1
        case Keysym.down: 1
        case Keysym.pageUp: -pageJump
        case Keysym.pageDown: pageJump
        default: nil
        }
    }

    private static func altCommand(
        keysym: UInt32,
        keycode: UInt32,
        modifiers: PickerModifiers
    ) -> PickerCommand {
        switch keysym {
        case Keysym.enter, Keysym.keypadEnter:
            return .choose(modifiers.contains(.shift) ? .plainText : .rich)
        case Keysym.lowercaseP, Keysym.uppercaseP:
            // Both cases: with Shift held, X11 reports the shifted keysym, and
            // Alt+Shift+P should still mean the same thing as Alt+P rather than
            // falling through to the search field as a stray "P".
            return .togglePin
        default:
            break
        }
        if let index = rowIndex(keysym: keysym, keycode: keycode) {
            return .chooseRow(index: index)
        }
        // Deliberately `.type` rather than "ignore": a modified key the picker
        // does not claim still belongs to the search field, which is where an
        // unrecognised keystroke does the least harm.
        return .type
    }

    /// The row Alt+1–9 picks, or `nil` when the key is not one of them.
    ///
    /// Two spellings, because one is not enough. The keysym is what the key
    /// *produces*, and on a QWERTY layout that is the digit — which is why it
    /// is checked first, and why it is the only thing the macOS picker needs
    /// (`PickerView.handleCommand` reads `keyPress.characters`, already
    /// resolved). On AZERTY the same physical keys produce `&`, `é`, `"`, `'`…
    /// unshifted, so a keysym-only match makes Alt+1–9 a QWERTY-only shortcut
    /// and silently sends the keystroke to the search field everywhere else.
    ///
    /// The keycode is what the key *is*, and it does not move with the layout.
    /// Checking it second recovers the gesture on every layout without taking
    /// it away from anyone: on QWERTY both paths agree.
    private static func rowIndex(keysym: UInt32, keycode: UInt32) -> Int? {
        if Keysym.one...Keysym.nine ~= keysym { return Int(keysym - Keysym.one) }
        if Keysym.digitRow ~= keycode { return Int(keycode - Keysym.digitRow.lowerBound) }
        return nil
    }
}

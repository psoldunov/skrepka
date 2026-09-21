/// Decides when automatic paste may leave the picker without carrying its
/// shortcut modifiers into the target application.
struct ModifierReleaseWait {
    enum Step: Equatable {
        case wait
        case proceed
    }

    private(set) var isWaiting = false

    mutating func begin(with modifiers: PickerModifiers) -> Step {
        guard modifiers.isDisjoint(with: .pasteBlocking) else {
            isWaiting = true
            return .wait
        }
        return .proceed
    }

    mutating func modifiersChanged(to modifiers: PickerModifiers) -> Step {
        guard isWaiting else { return .proceed }
        guard modifiers.isDisjoint(with: .pasteBlocking) else { return .wait }
        isWaiting = false
        return .proceed
    }

    mutating func timedOut() -> Step {
        isWaiting = false
        return .proceed
    }
}

extension PickerModifiers {
    static let superKey = PickerModifiers(rawValue: 1 << 26)
    static let pasteBlocking: PickerModifiers = [.shift, .control, .alt, .superKey]
}

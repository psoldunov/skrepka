/// Runs automatic paste only after the keyboard's live modifier state is clear.
final class ModifierReleaseWait {
    typealias Schedule = (@escaping () -> Void) -> () -> Void

    private let modifiers: () -> PickerModifiers
    private let schedulePoll: Schedule
    private let scheduleDeadline: Schedule
    private var cancelPoll: (() -> Void)?
    private var cancelDeadline: (() -> Void)?
    private var action: (() -> Void)?
    private(set) var isWaiting = false

    init(
        modifiers: @escaping () -> PickerModifiers,
        schedulePoll: @escaping Schedule = { _ in {} },
        scheduleDeadline: @escaping Schedule
    ) {
        self.modifiers = modifiers
        self.schedulePoll = schedulePoll
        self.scheduleDeadline = scheduleDeadline
    }

    func perform(_ action: @escaping () -> Void) {
        self.action = action
        guard !isWaiting else { return }
        guard !modifiers().isDisjoint(with: .pasteBlocking) else {
            finish()
            return
        }
        isWaiting = true
        cancelDeadline = scheduleDeadline { [weak self] in self?.finish() }
        cancelPoll = schedulePoll { [weak self] in self?.modifierStateChanged() }
    }

    func modifierStateChanged() {
        guard isWaiting, modifiers().isDisjoint(with: .pasteBlocking) else { return }
        finish()
    }

    func cancel() {
        cancelPoll?()
        cancelPoll = nil
        cancelDeadline?()
        cancelDeadline = nil
        action = nil
        isWaiting = false
    }

    private func finish() {
        let action = action
        cancel()
        action?()
    }
}

extension PickerModifiers {
    static let superKey = PickerModifiers(rawValue: 1 << 26)
    static let pasteBlocking: PickerModifiers = [.shift, .control, .alt, .superKey]
}

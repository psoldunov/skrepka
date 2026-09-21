/// Runs automatic paste only after the keyboard's live modifier state is clear.
final class ModifierReleaseWait {
    typealias ScheduleDeadline = (@escaping () -> Void) -> () -> Void

    private let modifiers: () -> PickerModifiers
    private let schedulePoll: ScheduleDeadline
    private let scheduleDeadline: ScheduleDeadline
    private var cancelPoll: (() -> Void)?
    private var cancelDeadline: (() -> Void)?
    private var actions: [() -> Void] = []
    private(set) var isWaiting = false

    init(
        modifiers: @escaping () -> PickerModifiers,
        schedulePoll: @escaping ScheduleDeadline = { _ in {} },
        scheduleDeadline: @escaping ScheduleDeadline
    ) {
        self.modifiers = modifiers
        self.schedulePoll = schedulePoll
        self.scheduleDeadline = scheduleDeadline
    }

    func perform(_ action: @escaping () -> Void) {
        actions.append(action)
        guard actions.count == 1 else { return }
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
        actions.removeAll()
        isWaiting = false
    }

    private func finish() {
        let ready = actions
        cancel()
        for action in ready { action() }
    }
}

extension PickerModifiers {
    static let superKey = PickerModifiers(rawValue: 1 << 26)
    static let pasteBlocking: PickerModifiers = [.shift, .control, .alt, .superKey]
}

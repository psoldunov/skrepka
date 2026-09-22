enum PickerPasteAction {
    /// Whether a `.copied` reply still belongs to the picker on screen: it is
    /// visible, and it is the opening the entry was chosen in.
    static func shouldComplete(isVisible: Bool, chosenOpening: Int?, currentOpening: Int) -> Bool {
        isVisible && chosenOpening == currentOpening
    }

    static func complete(
        isAutomatic: Bool,
        paster: (any PasteHandling)?,
        afterModifiersReleased: (@escaping () -> Void) -> Void = { $0() },
        hide: @escaping () -> Void
    ) {
        guard isAutomatic else {
            hide()
            return
        }
        afterModifiersReleased {
            hide()
            paster?.paste()
        }
    }
}

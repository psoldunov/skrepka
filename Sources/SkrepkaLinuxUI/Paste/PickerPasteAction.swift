enum PickerPasteAction {
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

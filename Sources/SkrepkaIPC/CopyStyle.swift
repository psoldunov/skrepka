/// How ``SkrepkaInterface/Member/copyAs`` writes an entry to the clipboard.
///
/// The Linux side of `PasteStyle` — Return and Alt+Shift+Return in the picker —
/// spelled as a wire value, because `SkrepkaIPC` depends on nothing that knows
/// what a paste style is and the interface carries strings rather than enums.
public enum CopyStyle: String, Sendable, Hashable, CaseIterable {
    /// Every representation the entry holds, as `Copy` has always written it.
    case rich
    /// The entry's text alone, so whatever it is pasted into cannot pick up
    /// its formatting — what ⇧⌘↩ does on macOS.
    case plain

    /// The wire spelling, or nil for one this build does not know — which the
    /// daemon refuses as an invalid argument rather than guessing at.
    public init?(wireValue: String) {
        self.init(rawValue: wireValue)
    }

    public var wireValue: String { rawValue }
}

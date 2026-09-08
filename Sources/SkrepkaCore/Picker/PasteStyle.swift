/// Whether a chosen entry pastes with its formatting or as plain text.
///
/// In `SkrepkaCore` rather than beside the picker that reads it, because both
/// platforms' pickers offer the same choice and a second spelling of a
/// two-case enum is a second thing to keep in step. Nothing here knows how
/// either platform performs the paste.
public enum PasteStyle: Sendable {
    case rich
    case plainText
}

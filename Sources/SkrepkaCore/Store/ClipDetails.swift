import Foundation

/// What a row needs that only reading the copied content can answer.
///
/// Grouped into one value because the three parts share a reason for existing:
/// none of them can be worked out from the pasteboard snapshot alone, each may
/// have to open a file, and they are therefore produced together, once, off the
/// main actor, by ``ThumbnailRenderer``.
///
/// Every part is optional in the same sense: nil means "not answered", never
/// "answered with nothing". A caller storing a fresh row falls back to what the
/// capture rules decided; a caller updating a row it already has keeps what is
/// there rather than overwriting a real answer with a missing one.
struct ClipDetails: Sendable, Hashable {
    /// What the file URL turned out to point at, or nil when the entry is not a
    /// file URL at all or the file system would not describe it — see
    /// ``FileURLKind``.
    let kind: ClipKind?
    /// The scaled picture and the original's pixel dimensions, or nil when the
    /// entry is not something Skrepka can draw.
    let preview: ThumbnailMaker.Preview?
    /// Size of the copied content — see ``ContentSize`` for which kinds have
    /// one and when it cannot be measured.
    let byteCount: Int?
}

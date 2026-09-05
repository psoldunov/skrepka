import Foundation

/// What a row needs that only reading the copied content can answer.
///
/// Grouped into one value because the two halves share a reason for existing:
/// neither the preview nor the size can be worked out from the pasteboard
/// snapshot alone, both may have to open a file, and both are therefore
/// produced once, off the main actor, by ``ThumbnailRenderer``.
struct ClipDetails: Sendable, Hashable {
    /// The scaled picture and the original's pixel dimensions, or nil when the
    /// entry is not something Skrepka can draw.
    let preview: ThumbnailMaker.Preview?
    /// Size of the copied content — see ``ContentSize`` for which kinds have
    /// one and when it cannot be measured.
    let byteCount: Int?
}

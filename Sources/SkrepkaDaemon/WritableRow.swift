import Foundation
import SkrepkaCore

/// One row, as ``Daemon/clipboardWrite(for:)`` needs it: what the row is, what
/// this device holds of it, and whether this device recorded it.
struct WritableRow: Sendable {
    let kind: ClipKind
    /// Pasteboard-keyed, as the store holds them.
    let representations: [String: Data]
    /// The files the row names, all of them — only used for a row recorded
    /// here, where the paths exist.
    let fileURLs: [URL]
    let preview: String
    let contentHash: String
    let isForeign: Bool
}

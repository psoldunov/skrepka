import Foundation
import SkrepkaCore

/// Pasting a file row another device recorded, from the picker.
///
/// Split from ``AppCoordinator`` because it is one rule with its own reasons —
/// never the other machine's path — and the coordinator is the file every
/// feature touches.
extension AppCoordinator {
    /// The row as ``ForeignFilePasteboard`` needs it, or nil when the paste
    /// writes the stored payload as it is: a row this Mac recorded, anything
    /// that is not a file copy, or a paste as plain text, which is a request
    /// for the names and gets them from the row's text.
    func foreignFileRow(
        for item: ClipSummary,
        contents: ClipContents,
        style: PasteStyle
    ) -> ForeignFilePasteboard.Row? {
        guard style == .rich, item.kind.isFileSystemEntry,
            let origin = store.origin(for: item.id), origin.isForeign
        else { return nil }
        return ForeignFilePasteboard.Row(
            kind: item.kind,
            representations: contents.payload.representations,
            preview: item.text,
            contentHash: origin.contentHash,
            isForeign: true
        )
    }

    /// The pasteboard items for `row`, or nil for none.
    nonisolated static func fileItems(
        for row: ForeignFilePasteboard.Row?,
        cache: FileCache?
    ) async -> [[String: Data]]? {
        guard let row else { return nil }
        return await ForeignFilePasteboard.items(for: row, cache: cache)
    }
}

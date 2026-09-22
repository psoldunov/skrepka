import Foundation
import SkrepkaIPC
import SkrepkaLinuxUI

/// A ``PickerDaemon`` with canned rows and no bus, so the picker can be driven —
/// and screenshotted — on a machine with no `skrepkad`. Immutable, so the
/// mutating members are no-ops that report success; the demo never asserts the
/// history changed.
final class FakePickerDaemon: PickerDaemon, Sendable {
    private let rows: [ClipDocument]
    /// The bytes the image row previews with, shared by every request for it.
    private let previewPNG: Data?

    init(rows: [ClipDocument], previewPNG: Data?) {
        self.rows = rows
        self.previewPNG = previewPNG
    }

    func history(limit: UInt32) async throws -> HistoryDocument {
        HistoryDocument(clips: rows, total: rows.count)
    }

    /// The daemon's `Search` semantics, so the demo's footer count and empty
    /// state behave as the real picker's: a blank query is the whole history,
    /// `total` counts the matches, and a non-zero `limit` trims them.
    func search(_ query: String, limit: UInt32) async throws -> HistoryDocument {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return HistoryDocument(clips: rows, total: rows.count) }
        let matches = rows.filter { $0.preview.lowercased().contains(needle) }
        let clips = limit == 0 ? matches : Array(matches.prefix(Int(limit)))
        return HistoryDocument(clips: clips, total: matches.count)
    }

    func copy(_ selector: ClipSelector, style: CopyStyle) async throws -> ActionDocument {
        .succeeded()
    }

    func setPinned(_ selector: ClipSelector, _ pinned: Bool) async throws -> ActionDocument {
        .succeeded()
    }

    func delete(_ selector: ClipSelector) async throws -> ActionDocument { .succeeded() }

    func preview(_ selector: ClipSelector, maxBytes: UInt32) async throws -> PreviewDocument {
        guard case .hash(let hash) = selector, let previewPNG,
            rows.first(where: { $0.contentHash == hash })?.hasPreview == true
        else {
            return .unavailable("No preview", contentHash: selector.wireValue)
        }
        return .picture(previewPNG, mediaType: "image/png", contentHash: hash)
    }

    /// A stream that never yields and never ends — the demo's history does not
    /// change, and a stream that finished would only make the link reconnect.
    func historyChanges() async throws -> AsyncStream<Void> {
        AsyncStream { _ in }
    }

    /// The file row caught part-way through arriving, so a screenshot shows the
    /// progress bar that stands in for a row's subtitle while its bytes come
    /// from a peer.
    func transfers() async throws -> TransfersDocument {
        guard let file = rows.first(where: { $0.kind == "file" }) else {
            return TransfersDocument(transfers: [])
        }
        return TransfersDocument(transfers: [
            .init(contentHash: file.contentHash, receivedBytes: 1_000_000, totalBytes: 2_400_000)
        ])
    }

    /// Never yields and never ends, for ``historyChanges()``'s reason: the
    /// demo's transfer stands still.
    func transferChanges() async throws -> AsyncStream<TransfersDocument> {
        AsyncStream { _ in }
    }
}

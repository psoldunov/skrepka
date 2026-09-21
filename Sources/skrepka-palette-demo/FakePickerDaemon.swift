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

    func search(_ query: String, limit: UInt32) async throws -> HistoryDocument {
        guard !query.isEmpty else { return HistoryDocument(clips: rows, total: rows.count) }
        let needle = query.lowercased()
        let matches = rows.filter { $0.preview.lowercased().contains(needle) }
        return HistoryDocument(clips: matches, total: rows.count)
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
}

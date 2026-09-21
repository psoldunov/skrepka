import Foundation
import SkrepkaCore

/// What each synced file row says about whether its files came — "contents
/// not synced" — keyed by entry id.
///
/// Only rows that could need it ask the store: a file row with no measured
/// size, which is every row learned from a peer, since a size describes the
/// copying machine's disk and never crosses the wire. A local file row is
/// measured at capture and never costs a lookup.
///
/// Answers that cannot change are kept: files that arrived stay arrived, and
/// a sender that attached none never attaches them later. A row still waiting
/// for its bytes, or over the file-size limit, is asked again on the next draw
/// — which is how its note goes away once they land, or once the limit is
/// raised.
final class SyncedFilesNoteCache {
    private let store: HistoryStore
    private let fileLimit: () -> Int
    private var settled: [UUID: SyncedFilesStatus?] = [:]

    init(store: HistoryStore, fileLimit: @escaping () -> Int) {
        self.store = store
        self.fileLimit = fileLimit
    }

    func note(for item: ClipSummary) -> String? {
        guard item.kind.isFileSystemEntry, item.byteCount == nil, !item.isConcealed else { return nil }
        if let known = settled[item.id] { return known?.rowNote }
        let status = store.syncedFilesStatus(for: item.id, fileLimit: fileLimit())
        if status?.canChange != true { settled[item.id] = status }
        return status?.rowNote
    }
}

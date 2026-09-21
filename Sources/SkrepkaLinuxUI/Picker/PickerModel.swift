import Foundation
import SkrepkaCore
import SkrepkaIPC

/// What the picker is showing and where the selection is, as a pure value.
///
/// The Linux counterpart of `Sources/Skrepka/Picker/PickerModel.swift`, minus
/// the store: the daemon lives in another process, so this holds only the rows
/// a reply handed it, the query, and the selection. Every mutation returns a
/// new value — the repository's immutability rule — and ``handling(_:)`` turns
/// a decoded key press into the next model and the one thing to ask the daemon,
/// which is what keeps the whole keyboard contract testable without a display.
///
/// The selection is tracked by content hash, not index, so a refresh that
/// reorders or drops rows keeps the user on the entry they were looking at
/// rather than on whatever slid into its slot.
public struct PickerModel: Equatable, Sendable {
    public private(set) var rows: [ClipDocument]
    public private(set) var query: String
    /// The `contentHash` the user is on, or nil for "the first row".
    public private(set) var selectedHash: String?

    public init(rows: [ClipDocument] = [], query: String = "", selectedHash: String? = nil) {
        self.rows = rows
        self.query = query
        self.selectedHash = selectedHash
    }

    public var isEmpty: Bool { rows.isEmpty }

    /// The selected row: the one whose hash matches, or the first when the hash
    /// names nothing in the current rows.
    public var selection: ClipDocument? {
        if let selectedHash, let match = rows.first(where: { $0.contentHash == selectedHash }) {
            return match
        }
        return rows.first
    }

    /// The selected row's index, for the list to reveal and highlight.
    public var selectedIndex: Int? {
        guard !rows.isEmpty else { return nil }
        if let selectedHash, let index = rows.firstIndex(where: { $0.contentHash == selectedHash }) {
            return index
        }
        return 0
    }

    // MARK: - Mutations

    /// Replaces the rows, keeping the selection on the same entry when it is
    /// still present and moving it to the top when it is not — which is what a
    /// fresh set of search results should do.
    public func withRows(_ rows: [ClipDocument]) -> PickerModel {
        let keep = selectedHash.flatMap { hash in rows.first { $0.contentHash == hash }?.contentHash }
        return PickerModel(rows: rows, query: query, selectedHash: keep ?? rows.first?.contentHash)
    }

    /// Records what is in the search field. The rows stay until a reply lands,
    /// so the list does not blank while the daemon is thinking.
    public func withQuery(_ query: String) -> PickerModel {
        PickerModel(rows: rows, query: query, selectedHash: selectedHash)
    }

    /// A fresh opening: the query cleared and the top row selected, matching the
    /// macOS `reset`.
    public func reset() -> PickerModel {
        PickerModel(rows: rows, query: "", selectedHash: rows.first?.contentHash)
    }

    public func movingSelection(by offset: Int) -> PickerModel {
        guard !rows.isEmpty else { return self }
        let current = selectedIndex ?? 0
        let next = min(max(current + offset, 0), rows.count - 1)
        return selecting(hash: rows[next].contentHash)
    }

    public func selectingFirst() -> PickerModel {
        guard let first = rows.first else { return self }
        return selecting(hash: first.contentHash)
    }

    public func selectingLast() -> PickerModel {
        guard let last = rows.last else { return self }
        return selecting(hash: last.contentHash)
    }

    /// Puts the selection on a specific entry — a hover or a click.
    public func selecting(hash: String) -> PickerModel {
        PickerModel(rows: rows, query: query, selectedHash: hash)
    }

    /// Drops a row and moves the selection to its neighbour — the row that
    /// slides into its place, or the new last row when the deleted one was
    /// last. Matches the macOS delete, which keeps a run of deletes walking
    /// down the list rather than snapping to the top.
    public func removing(hash: String) -> PickerModel {
        guard let index = rows.firstIndex(where: { $0.contentHash == hash }) else { return self }
        var remaining = rows
        remaining.remove(at: index)
        guard !remaining.isEmpty else { return PickerModel(rows: [], query: query, selectedHash: nil) }
        let neighbour = remaining[min(index, remaining.count - 1)].contentHash
        return PickerModel(rows: remaining, query: query, selectedHash: neighbour)
    }

    // MARK: - Commands

    /// The next model and the one thing to ask the daemon for a decoded press.
    ///
    /// A transcription of the macOS `PickerView.handle(keyPress:)`: navigation
    /// keys move the selection and ask for nothing; Return, Alt+N and Alt+P act
    /// on an entry; a `.type` is the search field's and changes nothing here.
    public func handling(_ command: PickerCommand) -> (model: PickerModel, effect: PickerEffect?) {
        switch command {
        case .moveSelection(let offset):
            return (movingSelection(by: offset), nil)
        case .selectFirst:
            return (selectingFirst(), nil)
        case .selectLast:
            return (selectingLast(), nil)
        default:
            return (self, effect(for: command))
        }
    }

    /// The effect an acting command asks of the daemon — the navigation cases
    /// never reach here, they only move the selection.
    private func effect(for command: PickerCommand) -> PickerEffect? {
        switch command {
        case .dismiss:
            return .dismiss
        case .choose(let style):
            return selection.map { .choose(hash: $0.contentHash, style: style.copyStyle) }
        case .chooseRow(let index):
            guard rows.indices.contains(index) else { return nil }
            return .choose(hash: rows[index].contentHash, style: .rich)
        case .togglePin:
            return selection.map { .setPinned(hash: $0.contentHash, pinned: !$0.isPinned) }
        case .deleteSelection:
            return selection.map { .delete(hash: $0.contentHash) }
        default:
            return nil
        }
    }
}

/// The single side effect a decoded key press asks of the daemon.
public enum PickerEffect: Equatable, Sendable {
    /// Put an entry on the clipboard and close.
    case choose(hash: String, style: CopyStyle)
    /// Pin or unpin an entry, leaving the picker open.
    case setPinned(hash: String, pinned: Bool)
    /// Delete an entry, leaving the picker open.
    case delete(hash: String)
    /// Close without acting.
    case dismiss
}

extension PasteStyle {
    /// The wire copy style this paste style asks the daemon for.
    var copyStyle: CopyStyle {
        switch self {
        case .rich: .rich
        case .plainText: .plain
        }
    }
}

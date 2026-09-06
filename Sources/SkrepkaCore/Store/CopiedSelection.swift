import Foundation

/// One look at every file in a copied selection.
///
/// A copy of three files asks the same two questions a copy of one does — what
/// are these, and how much do they weigh — and both answers come from the same
/// syscall per file. ``CopiedFile`` already made that true for a single file;
/// this makes it true for a list, so a selection of two hundred files is two
/// hundred `resourceValues` calls rather than four hundred.
///
/// The budget on *this* walk lives here for the same reason. Both readers used
/// to stat the list themselves, which meant an enormous selection paid
/// ``FileSelection/deadline`` twice over and could stop in different places each
/// time — reporting a kind for files it never sized. One stat walk, one
/// deadline, one answer both readers see.
///
/// Only the stat walk. Measuring a *folder* is a second walk that this one
/// cannot do for it — the size of a directory is everything underneath it, not
/// a field on the entry — so ``ContentSize/byteCount(of:deadline:)`` keeps a
/// budget of its own for that, and spends it across the whole selection rather
/// than per folder. What the two share is the constant, not the clock.
struct CopiedSelection: Sendable, Hashable {
    /// What the file system said about each file it would describe, in the order
    /// the selection listed them.
    ///
    /// Shorter than the selection when a file has been deleted, unmounted or
    /// sandboxed away since the copy — see ``CopiedFile/init(at:)``. Which files
    /// went missing is not recorded, because no reader asks: both turn a partial
    /// answer into no answer.
    let files: [CopiedFile]
    /// Whether every file in the selection was described, inside the deadline.
    ///
    /// The distinction both readers rest on. "I looked at all of them and they
    /// are pictures" is an answer; "I looked at four of two hundred before the
    /// budget ran out" is not, and calling the second one an answer is how a row
    /// reading "300 Images" gets downgraded to "300 Files" the first time that
    /// selection is re-copied off a cold volume.
    let isComplete: Bool

    /// Nothing looked at, and nothing to say about it — what an entry that names
    /// no file gets.
    static let empty = CopiedSelection(files: [], isComplete: false)

    /// Asks the file system about every URL, once each, inside one budget.
    ///
    /// Stops at ``FileSelection/deadline`` and reports the stop rather than the
    /// prefix it managed: a selection is measured all or nothing, and named all
    /// or nothing, so a truncated walk has nothing either reader can use.
    ///
    /// Empty in, and the result is ``empty`` — no walk, and `isComplete` false,
    /// which is what "there was nothing to look at" has to mean to a caller that
    /// would otherwise read an empty list as agreement.
    static func look(at urls: [URL], deadline: Duration = FileSelection.deadline) -> CopiedSelection {
        guard !urls.isEmpty else { return .empty }

        let clock = ContinuousClock()
        let start = clock.now
        var files: [CopiedFile] = []
        files.reserveCapacity(urls.count)

        for url in urls {
            if clock.now - start > deadline {
                return CopiedSelection(files: files, isComplete: false)
            }
            if let file = CopiedFile(at: url) { files.append(file) }
        }
        return CopiedSelection(files: files, isComplete: files.count == urls.count)
    }
}

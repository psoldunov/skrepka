/// Skrepka's own selection writes whose reports have not come back yet, and
/// what each report should do.
///
/// Both sessions hear their own writes back — see ``SelectionWrite`` — one
/// report per write, in order, but a round trip after the write was made. Two
/// writes close together are therefore both made before either report
/// arrives, and a report judged by whatever Skrepka owns *now* was judged by
/// the wrong write: two `skrepka copy` runs in a row were two captures of the
/// second, and a copy overtaken by a peer's handoff was judged as a handoff.
///
/// So every write is queued, every report takes the oldest one off, and only
/// the report of the newest write can publish:
///
/// - **A `.copy` still newest when its report arrives is published, once.**
/// - **A `.copy` overtaken by a later write is not published at all.** The
///   clipboard no longer holds it, and recording it would push content older
///   than the clipboard's to every peer — when the later write is a peer's
///   handoff, the very overwrite the handoff path exists to prevent.
/// - **A `.handoff` is never published.**
/// - **The empty selection ahead of a replacing write's report is not
///   published either** — see ``takeClear()``.
///
/// Measured in the Linux image on 2026-09-18 rather than assumed: an X server
/// reports every `SetSelectionOwner` Skrepka makes, including one that
/// re-takes a selection it already owns, and a Wayland compositor answers
/// every `set_selection` with an offer of its own — preceded by an empty
/// selection when the write replaced a source Skrepka was serving.
///
/// A write that produces no report of its own — a clear, a source that could
/// not be made, ownership lost to another client — ends the queue with
/// ``removeAll()``: whatever it superseded is no longer what the clipboard
/// holds either.
struct PendingEchoes: Sendable {
    private struct Pending: Sendable {
        let write: SelectionWrite
        let targets: Set<String>
        /// Whether an empty selection is still due ahead of this write's report.
        let clearIsDue: Bool
    }

    /// Writes kept before the oldest is dropped. One report per write drains
    /// the queue as fast as it fills, so this only bounds a report that never
    /// came, or a burst of writes larger than any a person makes.
    static let capacity = 16

    private var pending: [Pending] = []

    /// Skrepka just took the selection for `write`, offering `targets`.
    ///
    /// `afterClearing` is whether taking it destroyed a source Skrepka was
    /// serving, which a Wayland compositor reports as an empty selection ahead
    /// of this write's own. An X server reports a re-take with no clear.
    mutating func took(
        _ write: SelectionWrite,
        offering targets: some Sequence<String>,
        afterClearing: Bool = false
    ) {
        if pending.count >= Self.capacity { pending.removeFirst() }
        pending.append(Pending(write: write, targets: Set(targets), clearIsDue: afterClearing))
    }

    /// No report still due can be for content the clipboard holds.
    mutating func removeAll() {
        pending.removeAll()
    }

    /// Whether an offer of `targets` is the report of the oldest pending write.
    ///
    /// For Wayland, whose offers carry nothing that names their source: the
    /// target set is the only evidence, and it is compared with the write the
    /// report must belong to rather than with the newest one.
    func isReport(offering targets: [String]) -> Bool {
        guard let oldest = pending.first else { return false }
        return oldest.targets == Set(targets)
    }

    /// An empty selection arrived: whether it is the clear Skrepka's own write
    /// caused by destroying the source it replaced, rather than a real one.
    ///
    /// Absorbed at most once per write, and only ahead of that write's report,
    /// so a compositor that skips the clear leaves nothing behind to swallow a
    /// real one later. A real clear that lands in the same gap loses nothing by
    /// it: the pending write overwrote it before anybody could read it.
    mutating func takeClear() -> Bool {
        guard let oldest = pending.first, oldest.clearIsDue else { return false }
        pending[0] = Pending(write: oldest.write, targets: oldest.targets, clearIsDue: false)
        return true
    }

    /// The report of the oldest pending write arrived: whether to publish it.
    mutating func takeReport() -> Bool {
        guard !pending.isEmpty else { return false }
        let oldest = pending.removeFirst()
        return oldest.write == .copy && pending.isEmpty
    }
}

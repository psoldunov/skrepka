/// Why Skrepka is putting something on the clipboard, which decides whether the
/// write comes back as a capture.
///
/// Both sessions hear their own writes. A Wayland compositor answers a
/// `set_selection` with a `selection` event carrying Skrepka's own offer, and
/// an X server reports Skrepka taking ownership through `XFixesSelectionNotify`
/// like anyone else's — some time after the write was queued, because the
/// write is a command for the session's loop rather than a call that finishes
/// in place. Nothing above the session can time a pause around that echo, so
/// the session decides, from this, what the echo means.
public enum SelectionWrite: Sendable, Equatable {
    /// The user asked for it — `skrepka copy`.
    ///
    /// The echo is published like any other change, so the watcher captures
    /// it: the entry moves to the top of history and goes to peers, which is
    /// what every clipboard manager does with a copy the user made. Once, and
    /// only while it is still the newest write — see ``PendingEchoes``.
    case copy

    /// A peer's live push, handed over to this machine's clipboard.
    ///
    /// The echo is not published at all — the change counter does not move and
    /// nothing is read. The content is already in history, stored by the
    /// responder before the push reached the clipboard, and recapturing it
    /// would push it straight back to the device it came from.
    case handoff
}

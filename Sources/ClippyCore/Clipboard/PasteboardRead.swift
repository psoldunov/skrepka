import Foundation

/// The outcome of one attempt to read the general pasteboard.
///
/// Modelled rather than expressed as `PasteboardSnapshot?` because the nil case
/// carried two very different meanings — "nothing there" and "not allowed to
/// look" — and the second one was being dropped on the floor.
public enum PasteboardRead: Sendable, Hashable {
    case contents(PasteboardSnapshot)
    /// The change counter moved but the pasteboard handed back no item.
    ///
    /// Usually a denied read: macOS gates programmatic access to the general
    /// pasteboard (`NSPasteboardAccessBehavior` in `NSPasteboard.h`). It can
    /// also be a poll that landed between `clearContents()` and the write that
    /// follows it, which is why one of these means nothing and a run of them
    /// means the permission is missing — see ``CaptureHealth``.
    case unreadable
}

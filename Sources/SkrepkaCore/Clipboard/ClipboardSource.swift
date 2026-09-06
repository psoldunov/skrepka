import Foundation

/// Whatever the system calls "the clipboard", reduced to the three questions
/// ``ClipboardWatcher`` has to ask it.
///
/// ## Why the shape is what it is
///
/// The three backends this has to fit do not agree on how a change arrives.
/// macOS has no notification at all — `NSPasteboard.h` in the macOS 26 SDK
/// declares none — so `NSPasteboard.changeCount` has to be read on a timer.
/// X11 is the opposite: `XFixesSelectSelectionInput` registers for
/// `XFixesSelectionNotify`, and the selection change is delivered as a real
/// event. Wayland's data-control protocols are event-driven too.
///
/// A protocol built only around ``changeCount()`` would force the event-driven
/// backends to sit behind a timer and answer a question they were already told
/// the answer to. A protocol built only around a stream would force macOS to
/// synthesise events off a timer it then hides, which buries the one tunable
/// that matters there. So both are here, and they are not alternatives:
///
/// - ``changeCount()`` is the **identity** of the current selection. Every
///   backend has one, event-driven or not — an event-driven backend bumps a
///   counter in its event handler. It answers "is this the same selection I
///   already saw?", which is what stops Skrepka's own paste-back from being
///   recaptured, and what lets ``ClipboardWatcher/resume()`` discard whatever
///   happened while it was paused without reading a byte of content.
/// - ``changeNotifications()`` is the **schedule**. Returning a stream means
///   "I will tell you when to look"; returning `nil` means "I cannot, poll me".
///   It is defaulted to `nil`, so a polling backend writes two methods and an
///   event-driven one writes three.
///
/// The counter stays authoritative in both modes: a notification means *may
/// have changed*, and the watcher still asks ``changeCount()`` before reading
/// content. One authority, so a backend that over-notifies — X11 fires for
/// owner changes that change nothing, Wayland echoes your own writes — costs a
/// counter read rather than a duplicate history entry.
///
/// Deliberately *not* on this protocol: `accessBehavior()` and `probeAccess()`.
/// Both exist on ``PasteboardReader`` and both are answers to a macOS
/// permission model that X11 and Wayland do not have. Hoisting them here would
/// buy the Mac side a protocol requirement whose Linux conformance is a
/// constant — the cost D-9 exists to refuse. Diagnostics keeps talking to the
/// concrete reader.
///
/// Requirements are `async` so a backend holding a live connection can be an
/// `actor`; a synchronous function satisfies an `async` requirement, which is
/// how ``PasteboardReader`` conforms without changing a line of its body.
public protocol ClipboardSource: Sendable {
    /// Identity of the selection currently on the clipboard.
    ///
    /// Only required to *change* when the selection changes — it need not be
    /// monotonic, and nothing reads it as a count of anything.
    func changeCount() async -> Int

    /// Freezes the clipboard's current contents into a value.
    ///
    /// - Parameter sourceBundleID: Identifier of whatever had focus when the
    ///   copy happened, or nil when the platform cannot say.
    func read(sourceBundleID: String?) async -> PasteboardRead

    /// A stream that yields once each time the selection may have changed, or
    /// nil when the platform has no such notification and must be polled.
    ///
    /// Yielding spuriously is allowed and cheap — see the type's discussion.
    /// Failing to yield is not: a missed notification is a clipping the user
    /// never gets back.
    func changeNotifications() async -> AsyncStream<Void>?
}

extension ClipboardSource {
    /// Polling is the fallback, because macOS has nothing better.
    public func changeNotifications() -> AsyncStream<Void>? { nil }
}

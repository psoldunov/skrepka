import CXFixesShim
import Foundation
import SkrepkaCore

#if canImport(Glibc)
    import Glibc
#endif

/// The X11 clipboard, on one thread.
///
/// ## Event-driven, and better than macOS at it
///
/// `XFixesSelectSelectionInput` registers for `XFixesSelectionNotify`, so a
/// selection change arrives as a real event and nothing here polls. macOS is
/// the platform stuck on a timer: `NSPasteboard.h` in the macOS 26 SDK declares
/// no change notification of any kind.
///
/// ## Thread confinement
///
/// Exactly one thread ever touches the `Display`, which is what makes
/// `XInitThreads()` unnecessary — the Xlib manual is explicit that it is "only
/// necessary to call this function if multiple threads might use Xlib
/// concurrently. If all calls to Xlib functions are protected by some other
/// access mechanism (for example ... explicit client programming), Xlib thread
/// initialization is not required", and recommends single-threaded programs do
/// not call it. Not calling it also sidesteps its hardest requirement, that it
/// be the very first Xlib call in the process.
///
/// Like ``DataControlSession``, this class is deliberately not `Sendable` and
/// never leaves the thread that builds it.
final class XClipboardSession {
    enum Command: Sendable {
        case stop
        /// Own `CLIPBOARD` and serve these bytes, keyed by target name. `nil`
        /// relinquishes ownership.
        case setSelection([String: Data]?)
    }

    let state: LinuxClipboardState
    let notify: AsyncStream<Void>.Continuation
    /// Which server to connect to, or nil to let Xlib read `DISPLAY`.
    ///
    /// Passed rather than read for the same reason the Wayland session takes
    /// one: two sessions in one process must not have to agree on a variable.
    let displayName: String?

    var display: OpaquePointer?
    var window: Window = 0
    var atoms: XAtoms?
    /// Base event number XFIXES was assigned, from `XFixesQueryExtension`.
    /// `XFixesSelectionNotify` is 0, so a selection change arrives as exactly
    /// this type — confirmed against `libxfixes`'s own wire-to-event handler,
    /// which sets `aevent->type = awire->type & 0x7F`, the raw code.
    var xfixesEventBase: Int32 = 0
    var shouldStop = false
    var failure: String?

    /// The most recent timestamp the server has shown us.
    ///
    /// ICCCM forbids `CurrentTime` in `ConvertSelection` — "clients should not
    /// use CurrentTime for the time argument ... they should use the timestamp
    /// of the event that caused the request to be made" — and
    /// `XSetSelectionOwner` needs a real one too. Seeded at connect by
    /// provoking a `PropertyNotify` on our own window, then kept current from
    /// every event that carries a time.
    var lastServerTime: Time = 0

    // MARK: Reading

    enum ReadPhase: Equatable {
        case idle
        /// Waiting for the reply to a `TARGETS` conversion.
        case targets
        /// Waiting for the reply to one target's conversion.
        case data(Atom)
        /// Draining an `INCR` transfer for one target.
        case incremental(Atom)
    }

    var phase: ReadPhase = .idle
    /// Targets still to fetch, richest first.
    var remainingTargets: [Atom] = []
    /// Every target the owner advertised, by name — what the snapshot declares.
    var advertisedNames: [String] = []
    var payloads: [String: Data] = [:]
    var incrementalBytes = Data()
    var readDeadline: ContinuousClock.Instant?

    // MARK: Owning

    /// What Skrepka serves while it owns `CLIPBOARD`, keyed by target name.
    var ownedPayload: [String: Data] = [:]
    /// The same, resolved to atoms, so a `SelectionRequest` is a lookup rather
    /// than a round trip per request.
    var ownedByAtom: [Atom: Data] = [:]
    /// When ownership was taken. ICCCM §2.2 says a request whose timestamp
    /// falls outside the ownership period must be refused.
    var ownedSince: Time = 0
    var incomingTransfers: [XIncrementalSend] = []

    init(
        state: LinuxClipboardState,
        notify: AsyncStream<Void>.Continuation,
        displayName: String? = nil
    ) {
        self.state = state
        self.notify = notify
        self.displayName = displayName
    }

    func publish(_ read: PasteboardRead) {
        state.publish(read)
        notify.yield()
    }

    /// Records the newest timestamp seen, so the next request can quote one.
    func note(time: Time) {
        if time != 0 { lastServerTime = time }
    }
}

/// One `INCR` reply in progress, to one requestor.
///
/// ICCCM §2.7.2, owner side: append a chunk, wait for the requestor to delete
/// the property, append the next, and finish by writing a zero-length property.
/// The requestor's deletion is what paces the transfer, so this is a state
/// machine rather than a loop.
final class XIncrementalSend {
    let requestor: Window
    let property: Atom
    let type: Atom
    private let bytes: Data
    private let chunkBytes: Int
    private var offset = 0
    private(set) var isFinished = false
    private let deadline: ContinuousClock.Instant

    init(
        requestor: Window,
        property: Atom,
        type: Atom,
        bytes: Data,
        chunkBytes: Int,
        now: ContinuousClock.Instant = .now
    ) {
        self.requestor = requestor
        self.property = property
        self.type = type
        self.bytes = bytes
        self.chunkBytes = chunkBytes
        deadline = now.advanced(by: LinuxClipboardLimits.transferTimeout)
    }

    /// Writes the next chunk, or the zero-length property that ends the
    /// transfer.
    func sendNextChunk(display: OpaquePointer) {
        guard !isFinished else { return }
        let remaining = bytes.count - offset
        guard remaining > 0 else {
            // Zero length, same type and format: this is what tells the
            // requestor the data is complete.
            XProperty.write(
                bytes: Data(),
                display: display,
                window: requestor,
                property: property,
                type: type
            )
            finish(display: display)
            return
        }
        let count = min(remaining, chunkBytes)
        XProperty.write(
            bytes: bytes[bytes.startIndex + offset..<bytes.startIndex + offset + count],
            display: display,
            window: requestor,
            property: property,
            type: type
        )
        offset += count
    }

    func expireIfOverdue(display: OpaquePointer, now: ContinuousClock.Instant = .now) {
        guard !isFinished, now >= deadline else { return }
        finish(display: display)
    }

    /// Stops watching the requestor's window.
    ///
    /// Event masks are per-client — the Xlib manual: "Multiple clients can
    /// select input on the same window. Their event masks are maintained
    /// separately" — so clearing ours cannot disturb the requestor's own.
    func finish(display: OpaquePointer) {
        guard !isFinished else { return }
        isFinished = true
        XSelectInput(display, requestor, 0)
    }
}

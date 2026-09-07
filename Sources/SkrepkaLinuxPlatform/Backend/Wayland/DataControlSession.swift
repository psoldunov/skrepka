import CWaylandClient
import CWaylandProtocols
import Foundation
import SkrepkaCore
import Synchronization

#if canImport(Glibc)
    import Glibc
#endif

/// The whole Wayland data-control state machine, on one thread.
///
/// ## Thread confinement, and why it is not an actor
///
/// libwayland wants one thread driving one connection through a `poll` loop,
/// and every event arrives as a C callback that cannot `await`. So this class
/// is deliberately **not** `Sendable` and never leaves the thread that created
/// it: it is constructed inside ``run(commands:wakeup:)``, lives for that call,
/// and is torn down before it returns. Nothing outside can hold a reference.
///
/// Two Sendable things cross the boundary, and only these two:
/// ``LinuxClipboardState`` for the counter and the last read, and an
/// `AsyncStream.Continuation` for notifications, which its own documentation
/// says may be yielded to from any thread. Requests travelling the other way —
/// write this selection, stop — arrive through a `Mutex`-guarded queue and a
/// self-pipe.
///
/// The repo's concurrency rule asks for background work in an `actor`. This is
/// the case the rule's own escape applies to: an actor cannot own a `wl_display`
/// because the C callbacks that drive it have no isolation to hop to, and
/// pretending otherwise is what `MainActor.assumeIsolated` is for. The
/// confinement is enforced structurally — by the object never escaping — rather
/// than claimed in a comment.
final class DataControlSession: DataControlSessionEvents {
    /// A request from the actor to the loop.
    enum Command: Sendable {
        case stop
        /// Take ownership of the selection and serve these bytes, keyed by MIME
        /// target. `nil` clears the selection.
        case setSelection([String: Data]?)
    }

    let binding: any DataControlProtocolBinding
    let state: LinuxClipboardState
    let notify: AsyncStream<Void>.Continuation
    /// Which compositor to connect to, or nil to let libwayland read
    /// `WAYLAND_DISPLAY` itself.
    ///
    /// Passed rather than read from the environment so that two sessions can
    /// exist in one process without fighting over a variable — which is not a
    /// hypothetical, it is what the two integration suites do. libwayland takes
    /// an absolute path as-is and skips `XDG_RUNTIME_DIR` entirely in that case
    /// (verified against `connect_to_socket` in libwayland 1.22), so a full
    /// socket path here needs nothing else set.
    let displayName: String?

    // MARK: Connection

    var display: OpaquePointer?
    var registry: OpaquePointer?
    var registryListener: UnsafeMutablePointer<wl_registry_listener>?
    var seat: OpaquePointer?
    var manager: OpaquePointer?
    var device: OpaquePointer?
    var shouldStop = false
    /// Set when the loop gave up, and published so the actor can report why
    /// rather than looking merely idle.
    var failure: String?

    // MARK: Offers

    /// MIME targets each live offer has advertised, in the order it did.
    ///
    /// Keyed by the proxy because `offer` events arrive against the offer
    /// object and there may be more than one alive at a time — the protocol
    /// introduces the next selection's offer before telling you to destroy the
    /// last one's.
    var offeredTargets: [OpaquePointer: [String]] = [:]
    var currentOffer: OpaquePointer?

    // MARK: Capture in flight

    var inbound: [InboundTransfer] = []
    /// Every target the owner advertised for the capture in flight, which is
    /// what the snapshot declares — not the subset Skrepka asked to read.
    var captureTargets: [String] = []
    var isCapturing = false
    /// A capture a dispatch callback asked for and the loop has not issued yet.
    var pendingCapture: PendingCapture?
    /// Pipe write ends handed to libwayland and not yet sent.
    var queuedWriteEnds: [Int32] = []

    // MARK: Selection ownership

    var ownedSource: OpaquePointer?
    /// What ``ownedSource`` serves, keyed by MIME target.
    var ownedPayload: [String: Data] = [:]
    var outbound: [OutboundTransfer] = []

    init(
        binding: any DataControlProtocolBinding,
        state: LinuxClipboardState,
        notify: AsyncStream<Void>.Continuation,
        displayName: String? = nil
    ) {
        self.binding = binding
        self.state = state
        self.notify = notify
        self.displayName = displayName
    }

    /// The session as a `void *` for a C listener's `data` argument.
    var opaqueSelf: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    // MARK: - DataControlSessionEvents

    func didIntroduceOffer(_ offer: OpaquePointer) {
        offeredTargets[offer] = []
        binding.attachOfferListener(offer, session: opaqueSelf)
    }

    func offer(_ offer: OpaquePointer, advertises mimeType: String) {
        offeredTargets[offer, default: []].append(mimeType)
    }

    /// A new selection. Everything about the previous one is now void.
    ///
    /// The protocol is explicit that the client must destroy the previous
    /// offer on receiving this, and that the previous selection is ignored
    /// regardless — so an in-flight capture of it is abandoned rather than
    /// finished. Finishing it would publish bytes the clipboard no longer
    /// holds, under a change count that says they are current.
    func didReceiveSelection(_ offer: OpaquePointer?) {
        abandonCapture()
        if let previous = currentOffer, previous != offer {
            offeredTargets[previous] = nil
            binding.destroyOffer(previous)
        }
        currentOffer = offer

        guard let offer else {
            // The clipboard was cleared. Published rather than ignored: it is a
            // real change, and `CaptureRules` reads an empty snapshot as
            // `.rejectedEmpty` rather than storing anything.
            publish(
                .contents(PasteboardSnapshot(representations: [:], declaredTypes: []))
            )
            return
        }

        let targets = offeredTargets[offer] ?? []
        if isOwnOffer(targets: targets) {
            // Skrepka set this selection itself, so the bytes are already here.
            // Short-circuiting is an optimisation rather than a correctness
            // requirement — the loop is non-blocking, so receiving from our own
            // source would work too, at the cost of a round trip through a pipe
            // per representation. What it does buy for free is never recording
            // Skrepka's own paste-back as if an application had made it.
            publish(snapshot(fromOwnedPayloadOfferedAs: targets))
            return
        }

        beginCapture(from: offer, targets: targets)
    }

    /// The compositor has retired this data device — the protocol says the
    /// object is no longer valid and must be destroyed.
    ///
    /// There is nothing to reconnect to from inside the loop, so it stops and
    /// says why. Restarting is the actor's decision, not the loop's.
    func didFinish() {
        failure = "The compositor retired Skrepka's clipboard device."
        shouldStop = true
    }

    func sourceWasAskedToSend(mimeType: String, fileDescriptor: Int32) {
        guard let bytes = ownedPayload[mimeType] else {
            // Asked for something never offered. Closing is the only correct
            // answer: the requestor reads to EOF, and leaving it open hangs it.
            close(fileDescriptor)
            return
        }
        guard makeNonBlocking(fileDescriptor) else {
            close(fileDescriptor)
            return
        }
        outbound.append(OutboundTransfer(bytes: bytes, fileDescriptor: fileDescriptor))
    }

    /// Another client took the selection, so this source is dead.
    ///
    /// In-flight writes are *not* cancelled: a requestor that asked before the
    /// handover is still waiting on its pipe, and dropping it would leave that
    /// application with a truncated paste. They finish on their own.
    func sourceWasCancelled() {
        releaseOwnedSource()
    }

    // MARK: - Publishing

    func publish(_ read: PasteboardRead) {
        state.publish(read)
        notify.yield()
    }

    /// Whether an offer is the one Skrepka itself put on the clipboard.
    ///
    /// Compared by MIME set rather than by identity because the protocol hands
    /// back a fresh offer object for our own source and gives no way to
    /// correlate it with the source it came from. Getting this wrong in either
    /// direction is a slowdown, never a fault: a false negative costs one
    /// round trip through a pipe, and a false positive needs another client to
    /// own the selection while offering exactly Skrepka's target set, which is
    /// then indistinguishable from Skrepka's own by any means the protocol
    /// offers.
    func isOwnOffer(targets: [String]) -> Bool {
        ownedSource != nil && !ownedPayload.isEmpty && Set(targets) == Set(ownedPayload.keys)
    }

    private func snapshot(fromOwnedPayloadOfferedAs targets: [String]) -> PasteboardRead {
        .contents(
            LinuxSnapshotBuilder.snapshot(
                offeredTargets: targets,
                payloads: ownedPayload,
                concealedHintSecret: false
            )
        )
    }

    /// Sets `O_NONBLOCK` on one end of a pipe and nothing else.
    ///
    /// One end, which is why `pipe2(…, O_NONBLOCK)` is not used: that flag
    /// would land on the writing end too, and a well-behaved clipboard owner
    /// writing into a pipe it believes to be blocking will drop data on the
    /// `EAGAIN` it never expected to see.
    func makeNonBlocking(_ fileDescriptor: Int32) -> Bool {
        let flags = fcntl(fileDescriptor, F_GETFL, 0)
        guard flags >= 0 else { return false }
        return fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0
    }
}

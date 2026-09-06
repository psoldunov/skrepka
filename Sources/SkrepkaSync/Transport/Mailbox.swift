import Foundation
import NIOConcurrencyHelpers

/// Undrained elements a ``Mailbox`` holds before it treats its producer as
/// flooding.
///
/// A file-scope constant because Swift has no stored static properties on a
/// generic type, and a default argument has to name something it can see.
/// Sixteen is far above what a strictly turn-taking exchange ever queues — one
/// request, one answer — and far below what a frame of
/// ``SyncLimits/maximumFrameBodyBytes`` makes expensive to hold. It belongs
/// here rather than in ``SyncLimits`` because it bounds this queue rather than
/// anything the protocol puts on the wire.
private let defaultMailboxCapacity = 16

/// A bounded multi-consumer queue that a NIO event loop fills and an `actor`
/// drains.
///
/// `AsyncStream` is the obvious answer and does not fit: its iterator is a
/// `mutating` async call, which Swift refuses on an actor's stored property
/// because two `receive()`s could interleave across the suspension. Copying the
/// iterator per call happens to work because `AsyncStream.Iterator` shares its
/// storage, but that is an implementation detail to rely on, and a protocol
/// where two callers can take each other's replies is not a protocol.
///
/// So: an explicit mailbox, with delivery from any thread and two properties
/// worth stating plainly, because the obvious reading of each one is wrong.
///
/// **Waiters queue.** An actor does *not* serialise its own suspensions:
/// ``SyncConnection/receive()`` parks at `next()`, and actor reentrancy lets a
/// second `receive()` arrive while the first is still parked. An earlier version
/// of this type kept one waiter and overwrote it, which drops a
/// `CheckedContinuation` on the floor — a permanent hang and a
/// `SWIFT TASK CONTINUATION MISUSE`.
///
/// It is *not* the case that one connection has two readers, whatever an earlier
/// version of this comment said. A dialled connection is read by a
/// ``SyncInitiator`` and nothing else, an accepted one by a ``SyncResponder``
/// and nothing else, and a pair of machines holds one of each — see
/// ``PeerLink``. The queue is right anyway, and for a reason that outlives that:
/// a reader whose call suspends here can be re-entered by a second call on the
/// same actor, and two `receive()`s parked at once must be woken in the order
/// they arrived or one takes the other's reply. Keeping one waiter would still
/// be a dropped continuation the first time that happened.
///
/// **The queue is bounded.** `autoRead` is on, so the event loop keeps reading
/// and decoding whether or not anyone is draining. Nothing else applies
/// backpressure, so without ``capacity`` a peer that streams frames at a
/// responder parked on a pairing sheet grows this array until the process dies —
/// with no pin, no approval and no policy decision needed first. At the cap the
/// element is dropped and ``onOverflow(_:)``'s handler runs, which is where the
/// connection is closed: a peer that pipelines past a turn-taking protocol's
/// ceiling is not speaking it, and dropping frames while carrying on would be a
/// correctness bug rather than a defence.
final class Mailbox<Element: Sendable>: Sendable {
    private enum Pull {
        case value(Element)
        case finished
        case wait
    }

    private enum Delivery {
        case handOff(CheckedContinuation<Element?, Never>)
        case queued
        case dropped
        case overflowed((@Sendable () -> Void)?)
    }

    private struct State {
        var queued: [Element] = []
        /// Parked consumers in arrival order; woken from the front.
        var waiters: [CheckedContinuation<Element?, Never>] = []
        var finished = false
        var overflowed = false
        var onOverflow: (@Sendable () -> Void)?
    }

    let capacity: Int

    private let state = NIOLockedValueBox(State())

    init(capacity: Int = defaultMailboxCapacity) {
        self.capacity = capacity
    }

    /// Whether a producer has ever overrun ``capacity``.
    ///
    /// A record of what happened rather than a gate on what happens next.
    /// Overflow is not latched: draining makes room and delivery resumes, which
    /// matters for ``SyncServer``'s accept queue — a server whose queue filled
    /// once and then refused every peer forever would be a worse failure than
    /// the leak the ceiling exists to stop. On a frame mailbox it makes no
    /// difference, because the handler closes the channel.
    var hasOverflowed: Bool { state.withLockedValue { $0.overflowed } }

    /// Installs what happens when a producer overruns ``capacity``, and runs it
    /// straight away if that has already happened.
    ///
    /// Set from outside rather than taken at `init` because the thing to do is
    /// close the channel, and the channel does not exist when the pipeline's
    /// pieces are built. Frames that arrive in the gap are still capped, so the
    /// worst the gap costs is a bounded queue and a late close.
    func onOverflow(_ handler: @escaping @Sendable () -> Void) {
        let fireNow = state.withLockedValue { state -> Bool in
            state.onOverflow = handler
            return state.overflowed
        }
        if fireNow { handler() }
    }

    /// Hands an element to the longest-waiting consumer, or queues it.
    ///
    /// Silently drops anything delivered after ``finish()``: the consumer has
    /// been told the stream ended, and re-opening it would let a closed channel
    /// produce messages.
    ///
    /// Drops the element and signals when the queue is at ``capacity``. The drop
    /// alone would be a correctness bug — a lost frame in a protocol with no
    /// retransmission — which is why the handler's job is to end the connection
    /// rather than to carry on one frame short.
    func deliver(_ element: Element) {
        let delivery = state.withLockedValue { state -> Delivery in
            guard !state.finished else { return .dropped }
            if !state.waiters.isEmpty { return .handOff(state.waiters.removeFirst()) }
            guard state.queued.count < capacity else {
                state.overflowed = true
                return .overflowed(state.onOverflow)
            }
            state.queued.append(element)
            return .queued
        }
        switch delivery {
        case .handOff(let waiter): waiter.resume(returning: element)
        case .overflowed(let handler): handler?()
        case .queued, .dropped: break
        }
    }

    /// Ends the stream once everything already queued has been taken.
    ///
    /// Every parked consumer is woken with nil, not just the first: a waiter
    /// only parks when the queue is empty, so all of them are waiting on bytes
    /// that will now never arrive.
    func finish() {
        let waiters = state.withLockedValue { state -> [CheckedContinuation<Element?, Never>] in
            state.finished = true
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: nil) }
    }

    /// The next element, or nil once the stream has ended and drained.
    func next() async -> Element? {
        switch take() {
        case .value(let element): return element
        case .finished: return nil
        case .wait: break
        }

        return await withCheckedContinuation { continuation in
            // Re-checked under the lock: an element may have arrived between
            // the take above and this closure running, and a waiter parked
            // after `finish()` would never be resumed.
            let immediate = state.withLockedValue { state -> Element?? in
                if !state.queued.isEmpty { return .some(state.queued.removeFirst()) }
                if state.finished { return .some(nil) }
                state.waiters.append(continuation)
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    private func take() -> Pull {
        state.withLockedValue { state in
            if !state.queued.isEmpty { return .value(state.queued.removeFirst()) }
            return state.finished ? .finished : .wait
        }
    }
}

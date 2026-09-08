import Foundation
import Synchronization

/// Requests travelling from the actor to a backend's own thread.
///
/// A class wrapping the `Mutex` rather than the `Mutex` itself: `Mutex` is
/// noncopyable, so passing one to the thread body would mean threading
/// `borrowing` through every frame that touches it and would still not survive
/// being captured by the escaping closure a `Thread` takes. A `Sendable` class
/// around it is copyable, captures cleanly, and keeps the lock in one place.
///
/// Draining rather than reading: a command is acted on once, and leaving it in
/// the queue for a loop that wakes twice would clear the selection twice.
final class CommandQueue<Command: Sendable>: Sendable {
    private let storage = Mutex<[Command]>([])

    func append(_ command: Command) {
        storage.withLock { $0.append(command) }
    }

    func drain() -> [Command] {
        storage.withLock {
            let pending = $0
            $0 = []
            return pending
        }
    }
}

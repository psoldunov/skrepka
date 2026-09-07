import Foundation

#if canImport(Glibc)
    import Glibc
#endif

/// A self-pipe, so a thread parked in `poll` can be woken by another one.
///
/// Both Linux backends run a `poll` loop that blocks indefinitely when nothing
/// is in flight — every wakeup that matters arrives on a descriptor, which is
/// what keeps an idle clipboard watcher off the CPU entirely. That leaves no
/// way to say "stop" or "put this on the clipboard" from outside, and neither
/// libwayland nor Xlib publishes an interrupt for a blocked wait. Xlib in
/// particular ships nothing of the kind: the documented primitives are
/// `ConnectionNumber` and `XEventsQueued`, and building the wait yourself is
/// the sanctioned way to integrate either library into an event loop.
///
/// So the loop polls one extra descriptor and the actor writes a byte to it.
struct WakePipe: Sendable {
    let readEnd: Int32
    let writeEnd: Int32

    /// Fails only when the process is out of descriptors, which is the one
    /// condition under which a backend cannot start at all.
    init?() {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { return nil }
        for end in ends {
            _ = fcntl(end, F_SETFD, FD_CLOEXEC)
            // Non-blocking on both ends: a full pipe means a wakeup is already
            // pending, so `signal()` has nothing to add and must not wait to
            // add it, and `drain()` must be able to stop at the last byte.
            let flags = fcntl(end, F_GETFL, 0)
            if flags >= 0 { _ = fcntl(end, F_SETFL, flags | O_NONBLOCK) }
        }
        readEnd = ends[0]
        writeEnd = ends[1]
    }

    /// Wakes the loop. Safe from any thread, and safe to call more often than
    /// the loop wakes — a wakeup is a nudge to look at shared state, never a
    /// message in itself.
    func signal() {
        var byte: UInt8 = 1
        // Failure here means the pipe is full, which means the loop has not
        // drained the previous nudge yet — so the wakeup it is about to
        // process covers this one too. Nothing to report and nothing to retry.
        _ = write(writeEnd, &byte, 1)
    }

    func drain() {
        var scratch = [UInt8](repeating: 0, count: 64)
        while read(readEnd, &scratch, scratch.count) > 0 {}
    }

    func close() {
        Glibc.close(readEnd)
        Glibc.close(writeEnd)
    }
}

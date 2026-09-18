import CGtk4
import Foundation
import Glibc
import Testing

@testable import SkrepkaLinuxUI

/// The bridge from Swift's concurrency pool to GTK's main loop.
///
/// Each test runs its own `GMainContext` and iterates it on the test's thread,
/// so "delivered on the loop's thread" can be checked against that thread's own
/// identity, and no test depends on GTK or a display.
@Suite("Main-loop inbox")
struct MainLoopInboxTests {
    /// Iterates `context` until `done` or the deadline, and says which.
    static func iterate(_ context: OpaquePointer, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !done() {
            guard Date() < deadline else { return false }
            // Non-blocking plus a short sleep rather than a blocking iteration,
            // so a lost wake-up fails this test at the deadline instead of
            // hanging the suite.
            _ = g_main_context_iteration(context, 0)
            usleep(1000)
        }
        return true
    }

    @Test("messages posted from another thread arrive on the loop's thread, in order")
    func crossThreadDelivery() throws {
        let context = try #require(g_main_context_new())
        defer { g_main_context_unref(context) }
        let inbox = try MainLoopInbox<Int>()
        let loopThread = pthread_self()
        var received: [Int] = []
        var wrongThread = false
        let watch = try MainLoopWatch(inbox: inbox, context: context) { value in
            received.append(value)
            if pthread_equal(pthread_self(), loopThread) == 0 { wrongThread = true }
        }
        defer { watch.cancel() }

        Thread.detachNewThread {
            for value in 0..<200 { inbox.post(value) }
        }

        #expect(Self.iterate(context) { received.count == 200 })
        #expect(received == Array(0..<200))
        #expect(wrongThread == false)
    }

    @Test("a post from the loop's own thread is delivered on a later iteration, never inside the post")
    func noReentrancy() throws {
        let context = try #require(g_main_context_new())
        defer { g_main_context_unref(context) }
        let inbox = try MainLoopInbox<String>()
        var received: [String] = []
        let watch = try MainLoopWatch(inbox: inbox, context: context) { received.append($0) }
        defer { watch.cancel() }

        inbox.post("first")
        #expect(received.isEmpty)
        #expect(Self.iterate(context) { received == ["first"] })
    }

    @Test("nothing is delivered once the watch is cancelled")
    func cancelStopsDelivery() throws {
        let context = try #require(g_main_context_new())
        defer { g_main_context_unref(context) }
        let inbox = try MainLoopInbox<Int>()
        var count = 0
        let watch = try MainLoopWatch(inbox: inbox, context: context) { _ in count += 1 }
        watch.cancel()

        inbox.post(1)
        for _ in 0..<20 {
            _ = g_main_context_iteration(context, 0)
        }
        #expect(count == 0)
        // Still queued, not lost: a new watch would find it.
        #expect(inbox.take() == [1])
    }
}

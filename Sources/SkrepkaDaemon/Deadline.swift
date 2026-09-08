import Foundation

/// Bounds an operation that carries no deadline of its own.
///
/// ## Why the work runs in an unstructured task
///
/// The obvious shape — a `withThrowingTaskGroup` racing the work against a
/// sleep — does not bound anything here, because leaving a task group awaits
/// every child that is still running. Cancelling a child that is suspended
/// inside a NIO future does not make it return, so the group would sit on
/// scope exit for exactly as long as the operation it was supposed to cut off.
///
/// So the work goes in an unstructured `Task` that this can *abandon*: the
/// deadline cancels it, reports the expiry, and returns. An abandoned task
/// still holds whatever it was holding until its own awaits unwind, and that
/// is the honest cost — but the caller is free, which is the point when the
/// caller is a D-Bus method on a connection that dispatches serially.
enum Deadline {
    /// Runs `operation`, or throws `expiry` when `limit` passes first.
    ///
    /// - Parameters:
    ///   - limit: how long the operation may take in total.
    ///   - expiry: what to throw when it does not finish in time. Written for
    ///     a person, like every other error that reaches a client.
    ///   - operation: the work. Cancelled when the deadline passes and when
    ///     the caller's own task is cancelled, whether or not it is in a
    ///     position to notice.
    ///
    /// Throws `CancellationError` rather than `expiry` when it is the caller
    /// that was cancelled: a `stop()` part-way through a pair is not "the peer
    /// did not answer in time", and reporting it as one puts a wrong sentence
    /// in the journal and in front of the user.
    static func run<Answer: Sendable>(
        _ limit: Duration,
        expiry: any Error,
        operation: @escaping @Sendable () async throws -> Answer
    ) async throws -> Answer {
        let (outcomes, sink) = AsyncStream<Result<Answer, any Error>>.makeStream()
        let work = Task {
            do {
                sink.yield(.success(try await operation()))
            } catch {
                sink.yield(.failure(error))
            }
            sink.finish()
        }
        let timer = Task {
            try await Task.sleep(for: limit)
            work.cancel()
            sink.yield(.failure(expiry))
            sink.finish()
        }
        // `work` too, not only the timer: a cancelled caller ends the `for
        // await` below without an outcome, and without this the operation ran
        // on to completion holding its connection and its event loop slot
        // with nobody left to receive what it produced.
        defer {
            timer.cancel()
            work.cancel()
        }
        for await outcome in outcomes { return try outcome.get() }
        // The stream ended without an outcome, which is what `AsyncStream`
        // does when the iterating task is cancelled — both tasks here yield
        // before they finish it.
        if Task.isCancelled { throw CancellationError() }
        // Otherwise unreachable. Throwing the expiry rather than trapping,
        // because a deadline helper that crashes the daemon is worse than one
        // that reports a timeout.
        throw expiry
    }
}

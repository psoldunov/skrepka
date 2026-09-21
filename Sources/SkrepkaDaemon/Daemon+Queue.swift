import Foundation

extension Daemon {
    // MARK: - Serialising the lifecycle

    /// Runs `work` after everything already queued, and returns a handle to it.
    ///
    /// The daemon's own `enqueueLifecycle`. Bring-up, tear-down, opening the
    /// pairing window and restarting a listener all mutate the same half-dozen
    /// properties across several awaits, and an actor guarantees only that one
    /// of them runs at a time between suspension points — not that one finishes
    /// before the next begins.
    ///
    /// **Anything already inside queued work calls the `perform…` half
    /// directly.** Awaiting this from within it waits for itself.
    @discardableResult
    func enqueue(_ work: @escaping @Sendable (Daemon) async -> Void) -> Task<Void, Never> {
        let previous = lifecycleTail
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
        lifecycleTail = task
        return task
    }

    /// ``enqueue(_:)`` for work that answers with something, or throws.
    ///
    /// The queue itself stays `Task<Void, Never>`: it exists to order the
    /// lifecycle, and whether one piece of that work failed is the business of
    /// whoever awaits the returned handle, not of the piece queued behind it.
    ///
    /// A separate name rather than an overload of ``enqueue(_:)``: the two
    /// closure types differ only in `throws` and a return, which is exactly the
    /// shape that makes an existing `enqueue { await $0.performStop() }` a
    /// coin-toss for the type checker.
    func enqueueAnswering<Answer: Sendable>(
        _ work: @escaping @Sendable (Daemon) async throws -> Answer
    ) -> Task<Answer, any Error> {
        let previous = lifecycleTail
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { throw CancellationError() }
            return try await work(self)
        }
        // `try?` rather than a handled error: the tail's only job is to make
        // the next piece of queued work start after this one has finished, and
        // the error is delivered — unswallowed — to the caller awaiting `task`.
        lifecycleTail = Task { _ = try? await task.value }
        return task
    }
}

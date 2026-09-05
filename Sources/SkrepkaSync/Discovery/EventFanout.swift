import Foundation

/// One producer, many consumers, over `AsyncStream`.
///
/// An `AsyncStream` has a single buffer and hands each element to exactly one
/// consumer, so two `for await` loops over the same stream do not both see
/// every element — they partition them, and which loop gets which element is
/// not deterministic. Discovery has more than one consumer by design: a peer
/// list watching the browse and a pairing coordinator watching the same browse
/// must both see all three Macs, not two and one. So each caller is handed a
/// stream of its own, and this is what keeps those streams identical.
///
/// Owned by a ``PeerDiscovery`` conformance and mutated only from inside it, so
/// the order every subscriber sees is the order the owner delivered in.
struct EventFanout<Element: Sendable> {
    /// Identifies one subscription for the whole of its life, so a consumer
    /// that went away can be dropped without searching for its continuation.
    typealias Token = Int

    private var subscribers: [Token: AsyncStream<Element>.Continuation] = [:]
    private var nextToken: Token = 0

    /// A stream carrying everything ``deliver(_:)`` is given from now on, and
    /// the token that identifies it.
    ///
    /// `onTermination` is the only signal that a consumer stopped reading, and
    /// it fires both when that consumer's task ends and when ``finish()``
    /// closes the stream. It runs on no particular isolation, which is why it
    /// hands the token back out and the owner does the removal, rather than
    /// this type reaching into itself from a `@Sendable` closure.
    mutating func subscribe(
        whenTerminated terminated: @escaping @Sendable (Token) -> Void
    ) -> (token: Token, stream: AsyncStream<Element>) {
        let token = nextToken
        nextToken += 1
        let (stream, continuation) = AsyncStream<Element>.makeStream()
        continuation.onTermination = { _ in terminated(token) }
        subscribers[token] = continuation
        return (token, stream)
    }

    /// Drops one subscriber. Idempotent, because the termination handler that
    /// calls it also runs for a stream ``finish()`` has already closed.
    mutating func remove(_ token: Token) {
        subscribers.removeValue(forKey: token)?.finish()
    }

    func deliver(_ element: Element) {
        for continuation in subscribers.values { continuation.yield(element) }
    }

    /// Ends every subscriber's stream.
    ///
    /// Reusable afterwards: tokens are never reissued, so a subscription taken
    /// out after this call cannot be confused with one from before it, and the
    /// termination handlers this fires find nothing left to remove.
    mutating func finish() {
        let ending = subscribers
        subscribers.removeAll()
        for continuation in ending.values { continuation.finish() }
    }
}

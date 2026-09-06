#if canImport(dnssd)

    import Foundation
    import dnssd

    /// Carries one dns_sd operation's callbacks into structured concurrency.
    ///
    /// dns_sd callbacks are C function pointers, so they cannot capture
    /// anything: the only channel from the callback back to the caller is the
    /// `void *context` argument. This class is what that pointer points at. It
    /// holds an `AsyncStream.Continuation`, which is `Sendable`, so the class is
    /// legitimately `Sendable` too — no unchecked conformance, and no proof
    /// anyone has to take on trust.
    ///
    /// Ownership is manual because the C API demands it: ``retainedContext()``
    /// hands a `+1` reference to dns_sd, and the operation's owner calls
    /// ``release(context:)`` after `DNSServiceRefDeallocate`, at which point no
    /// further callback can arrive.
    final class DNSServiceReplySink<Reply: Sendable>: Sendable {
        /// What ``first(timeout:)`` saw.
        enum Outcome: Sendable {
            case reply(Reply)
            /// The stream finished without a reply — the operation was torn
            /// down first.
            case ended
            case timedOut
        }

        private let stream: AsyncStream<Reply>
        let continuation: AsyncStream<Reply>.Continuation

        init() {
            let (stream, continuation) = AsyncStream<Reply>.makeStream()
            self.stream = stream
            self.continuation = continuation
        }

        /// Hands dns_sd a `+1` reference to pass back as `context`.
        func retainedContext() -> UnsafeMutableRawPointer {
            Unmanaged.passRetained(self).toOpaque()
        }

        /// Reads the sink back inside a callback, without changing its count.
        static func sink(for context: UnsafeMutableRawPointer?) -> DNSServiceReplySink? {
            guard let context else { return nil }
            return Unmanaged<DNSServiceReplySink>.fromOpaque(context).takeUnretainedValue()
        }

        /// Balances ``retainedContext()``. Only safe once the operation's
        /// `DNSServiceRef` has been deallocated.
        static func release(context: UnsafeMutableRawPointer) {
            Unmanaged<DNSServiceReplySink>.fromOpaque(context).release()
        }

        /// Every callback, for an operation whose replies keep arriving.
        ///
        /// `DNSServiceRegister` calls back more than once — dns_sd.h:1275-1284
        /// — so a registration has to keep reading after ``first(timeout:)``
        /// answered. Safe to iterate afterwards because this class holds
        /// `stream` for its whole life: the iterator ``first(timeout:)``
        /// dropped was not the last reference to the stream's storage, so
        /// dropping it did not terminate it. One consumer at a time, which is
        /// the only way it is used — a `first(timeout:)` that has returned, and
        /// then a single watcher.
        var replies: AsyncStream<Reply> { stream }

        /// Waits for the operation's first callback.
        ///
        /// The timeout is the reason this is not a bare `for await`: a
        /// responder that never answers would otherwise hang the caller with no
        /// way out, and dns_sd has no deadline of its own.
        func first(timeout: Duration) async -> Outcome {
            await withTaskGroup(of: Outcome.self) { group in
                group.addTask { [stream] in
                    for await reply in stream { return .reply(reply) }
                    return .ended
                }
                group.addTask {
                    // A cancelled sleep means the other arm won; either way the
                    // group is about to be torn down, so there is nothing to
                    // report and nothing to clean up.
                    try? await Task.sleep(for: timeout)
                    return .timedOut
                }
                let outcome = await group.next() ?? .ended
                group.cancelAll()
                return outcome
            }
        }
    }

#endif

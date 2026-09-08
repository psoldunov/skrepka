import Foundation
import SkrepkaSync

/// Taking an advertisement down, and who is told about it.
///
/// Two teardowns, and the difference between them is one step. ``AvahiDiscovery/stopAdvertising()``
/// is the end of an advertisement: it gives the entry group back and then
/// *finishes* every stream ``AvahiDiscovery/advertisementFailures()`` handed
/// out, which is the protocol's signal that there is nothing more to come.
/// ``AvahiDiscovery/dropAdvertisement()`` is the same minus that last step, for
/// the cases where an advertisement is being **replaced** rather than ended — a
/// descriptor change, and a rebuild after avahi restarted. A caller whose
/// failure stream finishes is entitled to conclude the advertisement is over
/// for good, and neither of those is that.
///
/// The subscription itself lives here too, because the thing that finishes a
/// sink and the thing that hands one out are the same contract read from its
/// two ends.
extension AvahiDiscovery {
    /// Withdraws the advertisement. Idempotent, and does not throw.
    public func stopAdvertising() {
        dropAdvertisement()
        for sink in failureSinks.values { sink.finish() }
        failureSinks = [:]
    }

    /// Gives up the entry group and everything this side knows about the
    /// record, **keeping the failure sinks**.
    ///
    /// The teardown a replacement advertisement needs. See the discussion on
    /// this file for why that is a different operation from ending one.
    ///
    /// **`Free` is sent even when the group is expected to be gone already.**
    /// The rebuild path reaches here after `Server.StateChanged(RUNNING)`,
    /// which avahi emits on its way up from a restart *and* whenever it
    /// re-registers — a host-name change, for one — and in the second case the
    /// daemon is the same process and the group is still live and still
    /// publishing the old record. Dropping the path without freeing it would
    /// leave that record advertised with nothing left to withdraw it by.
    /// Against a daemon that really did restart the call is answered
    /// `org.freedesktop.Avahi.InvalidObject`, which is exactly what
    /// ``free(path:interface:method:)`` exists to discard.
    func dropAdvertisement() {
        entryGroupTask?.cancel()
        entryGroupTask = nil
        published = nil
        registrationValue = nil
        guard let path = entryGroupPath else { return }
        entryGroupPath = nil
        // Unstructured on purpose: the protocol says teardown does not throw
        // and does not suspend, and a `Free` that cannot be awaited is still
        // worth sending — avahi withdraws the record when the client
        // disconnects either way, so the worst case is that the record lives
        // until the connection closes.
        Task { [weak self] in
            await self?.free(
                path: path,
                interface: AvahiNames.Interface.entryGroup,
                method: AvahiNames.EntryGroup.free
            )
        }
    }

    /// Reports an advertisement that was confirmed and then stopped being
    /// published — a collision avahi could not rename around, or a failure.
    public func advertisementFailures() -> AsyncStream<DiscoveryError> {
        let (stream, continuation) = AsyncStream<DiscoveryError>.makeStream()
        let id = UUID()
        failureSinks[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeFailureSink(id) }
        }
        return stream
    }

    func removeFailureSink(_ id: UUID) {
        failureSinks[id] = nil
    }
}

import Foundation
import SkrepkaSync

/// Taking an advertisement down, and who is told about it.
///
/// Two teardowns, and they differ in two ways rather than one.
///
/// ``AvahiDiscovery/stopAdvertising()`` is the **end** of an advertisement: it
/// gives the entry group back and then *finishes* every stream
/// ``AvahiDiscovery/advertisementFailures()`` handed out, which is the
/// protocol's signal that there is nothing more to come.
/// ``AvahiDiscovery/dropAdvertisement()`` is for an advertisement being
/// **replaced** rather than ended — a descriptor change, and a rebuild after
/// avahi restarted. A caller whose failure stream finishes is entitled to
/// conclude the advertisement is over for good, and neither of those is that.
///
/// The second difference is that the replacement one **waits for the `Free`**
/// and the ending one cannot. Every caller of `dropAdvertisement()` publishes
/// again immediately, and a `Free` still in flight when `EntryGroupNew` runs
/// means two entry groups for one service name. Nothing follows
/// `stopAdvertising()`, so it has nothing to race and stays best-effort — which
/// is as well, because `PeerDiscovery` declares it neither `async` nor
/// `throws`.
///
/// The subscription itself lives here too, because the thing that finishes a
/// sink and the thing that hands one out are the same contract read from its
/// two ends.
extension AvahiDiscovery {
    /// Withdraws the advertisement. Idempotent, and does not throw.
    ///
    /// `PeerDiscovery` declares this neither `async` nor `throws`
    /// (`Sources/SkrepkaSync/Discovery/PeerDiscovery.swift:90`), so the `Free`
    /// here cannot be awaited and is sent best-effort. That is the right trade
    /// at this call site and only at this one: nothing follows a final
    /// withdrawal, so there is no new entry group for the old one to race, and
    /// blocking a shutdown on a round trip to a daemon that may itself be going
    /// away is worse than letting the connection close withdraw the record.
    /// The **replacement** paths use ``dropAdvertisement()``, which waits.
    public func stopAdvertising() {
        dropAdvertisementBestEffort()
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
    /// **The `Free` is awaited**, and that is the whole difference from
    /// ``stopAdvertising()``. Every caller of this one publishes again
    /// immediately afterwards, so sending `Free` without waiting lets
    /// `EntryGroupNew` run while avahi is still destroying the old group — and
    /// for the moment both exist this device advertises `_skrepka._tcp` twice
    /// under one name, which is the duplicate-record case
    /// ``SkrepkaSync/ServiceRegistration`` exists to reason about.
    ///
    /// Awaited directly on the actor rather than from a `Task { [weak self] }`,
    /// so the caller genuinely waits. The unstructured version could outlive
    /// the actor and park against a ``SkrepkaIPC/BusSession`` that is still up,
    /// which is a suspended task holding a connection for a record nobody is
    /// left to withdraw.
    func dropAdvertisement() async {
        guard let path = forgetAdvertisement() else { return }
        await free(
            path: path,
            interface: AvahiNames.Interface.entryGroup,
            method: AvahiNames.EntryGroup.free
        )
    }

    /// ``dropAdvertisement()`` for the one caller that cannot suspend.
    ///
    /// Only ``stopAdvertising()`` may use this — see the reasoning there. A
    /// `Free` that cannot be awaited is still worth sending: avahi withdraws
    /// the record when the client disconnects either way, so the worst case is
    /// that the record outlives this call by the life of the connection.
    private func dropAdvertisementBestEffort() {
        guard let path = forgetAdvertisement() else { return }
        Task { [weak self] in
            await self?.free(
                path: path,
                interface: AvahiNames.Interface.entryGroup,
                method: AvahiNames.EntryGroup.free
            )
        }
    }

    /// Clears everything this side knows about the record and hands back the
    /// entry-group path still owing a `Free`, or nil when there is none.
    ///
    /// `entryGroupPath` is cleared **before** either caller frees it, which is
    /// what keeps `discardEntryGroup(at:)`'s `entryGroupPath == path` guard
    /// (`AvahiDiscovery+Advertising.swift`) able to refuse a second `Free` on a
    /// group avahi no longer has.
    private func forgetAdvertisement() -> String? {
        entryGroupTask?.cancel()
        entryGroupTask = nil
        published = nil
        registrationValue = nil
        guard let path = entryGroupPath else { return nil }
        entryGroupPath = nil
        return path
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

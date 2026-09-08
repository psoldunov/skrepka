import DBUS
import Foundation
import Logging
import SkrepkaSync

extension AvahiDiscovery {
    /// Publishes this device, and returns once avahi has confirmed the entry
    /// group is established.
    ///
    /// Waits for `StateChanged(established)` rather than returning after
    /// `Commit`, because the protocol says ``registration`` is readable
    /// afterwards and a committed group has not necessarily been accepted: a
    /// name may be taken, in which case the publish moves to the next name and
    /// tries again, and the name it settles on is only knowable once it has
    /// settled. See `AvahiDiscovery+Collision.swift`.
    public func startAdvertising(_ descriptor: ServiceDescriptor) async throws {
        guard published == nil else { throw DiscoveryError.alreadyAdvertising }
        try await publish(descriptor)
    }

    /// Does the least the change needs, and publishes outright when nothing is.
    ///
    /// The cheap implementation — withdraw and republish — takes the device off
    /// every peer's browse list and puts it back, and the changes that happen
    /// while a user is pairing are almost all TXT-only. `UpdateServiceTxt` is
    /// avahi's in-place replacement and covers exactly the
    /// ``SkrepkaSync/AdvertisementChange/record`` case.
    public func updateAdvertisement(_ descriptor: ServiceDescriptor) async throws {
        guard let published else {
            try await publish(descriptor)
            return
        }
        switch AdvertisementChange.between(published: published, wanted: descriptor) {
        case .unchanged:
            return
        case .record:
            try await updateRecord(descriptor)
        case .republish:
            // ``dropAdvertisement()`` rather than ``stopAdvertising()``: this
            // advertisement is being replaced, not ended, and finishing the
            // streams ``advertisementFailures()`` handed out would tell every
            // listener the record is gone for good. A descriptor change is not
            // that. The same teardown `republish(_:)` uses, for the same
            // reason.
            dropAdvertisement()
            try await publish(descriptor)
        }
    }

    // MARK: - The entry group

    func publish(_ descriptor: ServiceDescriptor) async throws {
        let record: TXTRecord
        do {
            record = try descriptor.txtRecord()
        } catch {
            throw DiscoveryError.advertisingFailed(reason: describe(error))
        }

        // The loss watch is subscribed here rather than in the commit loop
        // because it has to outlive every attempt: it is the stream that reports
        // the group being withdrawn *after* it was established, and a
        // subscription taken at that point would miss a collision that arrives
        // in the same instant.
        //
        // **Two subscriptions to the same signal, not one split in half.** The
        // commit loop takes its own for each attempt. Handing one stream's
        // iterator between them would be neater and does not compile —
        // `AsyncStream.Iterator` is not `Sendable`, and rightly so, since two
        // consumers of one stream would split its elements between them.
        // Subscribing twice is what the library supports, and each subscriber
        // sees every message.
        let losses: AsyncStream<DBusMessage>
        let path: String
        do {
            losses = try await signals(
                interface: AvahiNames.Interface.entryGroup,
                member: AvahiNames.EntryGroup.stateChanged
            )
            path = try await newEntryGroup()
        } catch {
            throw DiscoveryError.advertisingFailed(reason: describe(error))
        }

        entryGroupPath = path
        ensureServerWatch()
        do {
            try await commitUntilGranted(descriptor, record: record, losses: losses, at: path)
        } catch {
            // Every throwing path below this line — an `AddService` avahi
            // refuses, a `Commit` that errors, a registration that times out,
            // and the four-names-exhausted case at the end of
            // ``commitUntilGranted(_:record:losses:at:)`` — leaves a group
            // created and not owned. One `catch` covers them all, which is why
            // the `Free` is here rather than at each throw.
            await discardEntryGroup(at: path)
            throw error
        }
    }

    /// Gives back a group this publish created and did not go on to own.
    ///
    /// **The path is cleared**, because it is only meaningful for a group this
    /// instance is holding. Left set after a failed publish it is worse than
    /// stale: ``startAdvertising(_:)`` guards on `published`, which a failed
    /// publish never assigns, so the next attempt walks past that guard into
    /// ``publish(_:)`` and overwrites `entryGroupPath` — orphaning this group
    /// with no path left to free it by.
    ///
    /// **`Free` is sent**, because avahi reclaims an abandoned group when the
    /// client disconnects and not before — a bound that means nothing to a
    /// daemon retrying a publish every thirty seconds through a long outage.
    ///
    /// Narrower than the macOS shape at
    /// `BonjourDiscovery+Advertising.swift:161`, which calls its whole
    /// `stopAdvertising()`. Here that would finish the streams
    /// ``advertisementFailures()`` handed out, and a publish that failed is not
    /// grounds to tell every listener the advertisement is over for good.
    func discardEntryGroup(at path: String) async {
        // Only if it is still this publish's group. ``reportLoss(_:)`` runs
        // ``stopAdvertising()``, which clears the path and frees it, and a
        // second `Free` on the same path would be sent to a group avahi no
        // longer has.
        guard entryGroupPath == path else { return }
        entryGroupPath = nil
        do {
            _ = try await call(
                path: path,
                interface: AvahiNames.Interface.entryGroup,
                method: AvahiNames.EntryGroup.free
            )
        } catch {
            // Debug rather than a warning, for the reason ``free(path:interface:method:)``
            // discards its answer entirely: a group whose `Commit` failed has
            // often been destroyed by avahi already, and that is answered
            // `org.freedesktop.Avahi.InvalidObject`. Logged rather than
            // discarded because this one is reached with a publish error on its
            // way out, and a reader working out why the publish failed is owed
            // the fact that the cleanup after it failed too.
            logger.debug(
                "could not give back the entry group a failed publish created",
                metadata: ["path": "\(path)", "reason": "\(describe(error))"])
        }
    }

    private func newEntryGroup() async throws -> String {
        let reply = try await callServer(AvahiNames.Server.entryGroupNew)
        guard case .objectPath(let path) = reply.first else {
            throw AvahiError.unreadableReply(method: AvahiNames.Server.entryGroupNew)
        }
        return path
    }

    /// Adds the service under `name`, which is the descriptor's own name on the
    /// first attempt and an alternative on any attempt after a collision.
    func addService(
        _ descriptor: ServiceDescriptor,
        name: String,
        record: TXTRecord,
        at path: String
    ) async throws {
        _ = try await call(
            path: path,
            interface: AvahiNames.Interface.entryGroup,
            method: AvahiNames.EntryGroup.addService,
            [
                .int32(AvahiNames.unspecifiedInterface),
                .int32(AvahiNames.unspecifiedProtocol),
                .uint32(0),
                .string(name),
                .string(ServiceDescriptor.serviceType),
                // Empty domain and empty host mean "the defaults avahi already
                // knows" — `local` and this machine's own name. Naming them
                // would hard-code answers the daemon is the authority on.
                .string(""),
                .string(""),
                .uint16(descriptor.port),
                AvahiSignals.txtArgument(record),
            ]
        )
    }

    private func updateRecord(_ descriptor: ServiceDescriptor) async throws {
        guard let path = entryGroupPath, let name = registrationValue?.name else {
            try await publish(descriptor)
            return
        }
        do {
            let record = try descriptor.txtRecord()
            _ = try await call(
                path: path,
                interface: AvahiNames.Interface.entryGroup,
                method: AvahiNames.EntryGroup.updateServiceTxt,
                [
                    .int32(AvahiNames.unspecifiedInterface),
                    .int32(AvahiNames.unspecifiedProtocol),
                    .uint32(0),
                    // The name avahi granted, not the one that was asked for —
                    // a renamed service is updated under the name it actually
                    // has, and passing the requested one silently updates
                    // nothing.
                    .string(name),
                    .string(ServiceDescriptor.serviceType),
                    .string(""),
                    AvahiSignals.txtArgument(record),
                ]
            )
        } catch {
            throw DiscoveryError.advertisingFailed(reason: describe(error))
        }
        published = descriptor
    }

    /// Keeps reading the group's state after it was established, so a record
    /// withdrawn later is reported rather than silently gone.
    ///
    /// This stream has been open since before the group was created, so it
    /// replays every state the commit loop already saw — **including the
    /// collisions that loop renamed its way out of**. Reporting those would turn
    /// a publish that succeeded under a second name into an immediate
    /// `advertisingLost`, so the replay is skipped by waiting for the
    /// `established` the commit loop stopped on: everything before it is
    /// history, everything after it is news.
    func watchForLoss(_ losses: AsyncStream<DBusMessage>, at path: String) {
        entryGroupTask = Task { [weak self] in
            var isEstablished = false
            for await message in losses {
                guard !Task.isCancelled else { return }
                guard message.path == path,
                    let (state, detail) = AvahiSignals.entryGroupState(message.body)
                else { continue }
                switch state {
                case .established:
                    isEstablished = true
                case .collision where isEstablished:
                    await self?.reportLoss(.advertisingLost(reason: "the service name was taken"))
                    return
                case .failure where isEstablished:
                    await self?.reportLoss(.advertisingLost(reason: detail))
                    return
                case .uncommitted, .registering, .collision, .failure:
                    continue
                }
            }
        }
    }

    func reportLoss(_ error: DiscoveryError) {
        for sink in failureSinks.values { sink.yield(error) }
        // The protocol says a stream finishes one element after the loss it
        // reported, and that `stopAdvertising()` is what finishes it.
        stopAdvertising()
    }
}

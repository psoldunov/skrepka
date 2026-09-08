import DBUS
import Foundation
import Logging
import SkrepkaSync

/// Committing an entry group, and renaming around a name that is taken.
///
/// Two Steam Decks out of the box are both called `steamdeck`, so this is the
/// ordinary case rather than the exotic one. avahi does **not** rename by
/// itself over D-Bus — the auto-rename in `avahi-client` is client-side, and the
/// `EntryGroup` interface has none of it — so the loop below is what
/// mDNSResponder gives `BonjourDiscovery` for free by omitting
/// `kDNSServiceFlagsNoAutoRename`.
///
/// The sequence per attempt is avahi's own: `Reset`, `AddService` under the next
/// name, `Commit`. `Reset` matters — an entry group that has collided keeps the
/// entries that collided, and adding to it without resetting re-registers the
/// name that just failed.
extension AvahiDiscovery {
    /// How many names one publish is worth trying, the requested one included.
    ///
    /// Four, because `GetAlternativeServiceName` counts upwards — `steamdeck`,
    /// `steamdeck #2`, `steamdeck #3`, `steamdeck #4` — and a network with four
    /// machines contending for one label has a problem no retry fixes.
    static let nameAttempts = 4

    /// What one committed attempt came back as.
    ///
    /// `failure` and a silent daemon are not here: both are thrown, because
    /// neither is worth another name.
    enum CommitOutcome: Sendable {
        case established
        case collision
    }

    /// Commits under the requested name, then under each alternative avahi
    /// offers, and records the name that was actually granted.
    func commitUntilGranted(
        _ descriptor: ServiceDescriptor,
        record: TXTRecord,
        losses: AsyncStream<DBusMessage>,
        at path: String
    ) async throws {
        var name = descriptor.displayName
        var isRetry = false
        for attempt in 1...Self.nameAttempts {
            let states = try await commit(
                descriptor, name: name, record: record, at: path, afterCollision: isRetry)
            isRetry = true
            let outcome = try await Self.firstOutcome(
                states, at: path, within: Self.registrationTimeout)
            if case .established = outcome {
                grant(name, of: descriptor, losses: losses, at: path)
                return
            }
            logger.notice(
                "the service name is taken; trying the next one",
                metadata: ["name": "\(name)", "attempt": "\(attempt)"])
            guard attempt < Self.nameAttempts else { break }
            name = try await alternativeName(for: name)
        }
        throw DiscoveryError.advertisingFailed(
            reason: "another device on this network is already called that, "
                + "and \(Self.nameAttempts - 1) alternatives were taken too")
    }

    /// Records the name avahi actually granted, and starts watching for the
    /// advertisement being withdrawn later.
    ///
    /// `name` rather than `descriptor.displayName`: the two differ exactly when
    /// the commit loop went round, and a ``SkrepkaSync/ServiceRegistration``
    /// holding the requested name would have `UpdateServiceTxt` address a
    /// service that is not there — which avahi answers by doing nothing.
    private func grant(
        _ name: String,
        of descriptor: ServiceDescriptor,
        losses: AsyncStream<DBusMessage>,
        at path: String
    ) {
        published = descriptor
        recordAdvertisementWorking()
        registrationValue = ServiceRegistration(
            name: name,
            serviceType: ServiceDescriptor.serviceType,
            domain: "local",
            port: descriptor.port
        )
        watchForLoss(losses, at: path)
    }

    /// One attempt: subscribe, reset if this follows a collision, add, commit.
    ///
    /// The subscription is taken per attempt and before the `Commit` it belongs
    /// to, for the reason the browse subscribes early — avahi answers a `Commit`
    /// with a `StateChanged` that can arrive before a subscription taken
    /// afterwards is in place.
    private func commit(
        _ descriptor: ServiceDescriptor,
        name: String,
        record: TXTRecord,
        at path: String,
        afterCollision: Bool
    ) async throws -> AsyncStream<DBusMessage> {
        do {
            let states = try await signals(
                interface: AvahiNames.Interface.entryGroup,
                member: AvahiNames.EntryGroup.stateChanged
            )
            if afterCollision {
                _ = try await call(
                    path: path,
                    interface: AvahiNames.Interface.entryGroup,
                    method: AvahiNames.EntryGroup.reset
                )
            }
            try await addService(descriptor, name: name, record: record, at: path)
            _ = try await call(
                path: path,
                interface: AvahiNames.Interface.entryGroup,
                method: AvahiNames.EntryGroup.commit
            )
            return states
        } catch {
            throw DiscoveryError.advertisingFailed(reason: describe(error))
        }
    }

    /// The name avahi would try next, given this one.
    private func alternativeName(for name: String) async throws -> String {
        do {
            let reply = try await callServer(
                AvahiNames.Server.alternativeServiceName, [.string(name)])
            guard case .string(let alternative) = reply.first, !alternative.isEmpty else {
                throw AvahiError.unreadableReply(
                    method: AvahiNames.Server.alternativeServiceName)
            }
            return alternative
        } catch {
            throw DiscoveryError.advertisingFailed(reason: describe(error))
        }
    }

    /// The first state that settles the attempt, or the deadline.
    ///
    /// `nonisolated static` for the reason the resolver's wait is: its children
    /// must not hop onto this actor for every entry-group signal in the process,
    /// including the ones for some other group.
    private nonisolated static func firstOutcome(
        _ states: AsyncStream<DBusMessage>,
        at path: String,
        within timeout: Duration
    ) async throws -> CommitOutcome {
        try await withThrowingTaskGroup(of: CommitOutcome.self) { group in
            group.addTask { try await Self.settled(states, at: path) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw DiscoveryError.advertisingFailed(
                    reason: "avahi did not say what it did with the service")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw DiscoveryError.advertisingFailed(
                    reason: "avahi did not say what it did with the service")
            }
            return first
        }
    }

    private nonisolated static func settled(
        _ states: AsyncStream<DBusMessage>,
        at path: String
    ) async throws -> CommitOutcome {
        for await message in states {
            guard message.path == path,
                let (state, detail) = AvahiSignals.entryGroupState(message.body)
            else { continue }
            switch state {
            case .uncommitted, .registering:
                continue
            case .established:
                return .established
            case .collision:
                return .collision
            case .failure:
                throw DiscoveryError.advertisingFailed(
                    reason: detail.isEmpty ? "avahi could not publish the service" : detail)
            }
        }
        throw DiscoveryError.advertisingFailed(reason: "avahi stopped answering while publishing")
    }
}

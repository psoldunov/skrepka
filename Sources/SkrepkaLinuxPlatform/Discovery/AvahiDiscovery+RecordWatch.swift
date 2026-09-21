import DBUS
import Foundation
import Logging
import SkrepkaSync

/// Following each sighted peer's TXT record, so a record rewritten in place is
/// noticed.
///
/// One `RecordBrowser` per instance, created at the service browser's first
/// `ItemNew` for it and freed when its last `ItemRemove` arrives. Every change
/// it reports goes out as ``SkrepkaSync/DiscoveryEvent/changed(_:)`` carrying
/// the new advertisement, which the daemon files over the old sighting. See
/// ``PeerRecordWatch`` for why this exists and what counts as a change.
///
/// **Subscribed before any browser exists**, for the reason the service browse
/// is: the signal library filters on interface and member, not path, so one
/// subscription taken at browse start hears every record browser this process
/// will ever create. The one gap left is a signal arriving before the
/// `RecordBrowserNew` reply has been read — avahi 0.8 starts the browser as it
/// answers — and ``claim(_:for:)`` closes that by holding such signals until
/// their path is known.
///
/// **Deliberately keyed by instance name alone**, across every interface.
/// Two different devices advertising the same instance name on two different
/// links would share one watch, and one browser that hears both records would
/// report them alternately as the same peer changing. What that costs: the
/// daemon's sighting for that name flips between the two devices until one is
/// renamed. It needs two links and a name collision the peers' own responders
/// did not resolve, so the simpler key was taken.
extension AvahiDiscovery {
    /// How many signals for not-yet-known paths are held. A handful is the
    /// realistic most — one replayed record per browser being created — and
    /// the cap stops a stream of signals for someone else's paths growing
    /// without bound.
    static let unclaimedSignalLimit = 64

    /// Subscribes to the three record-browser signals. Called by the browse
    /// before `ServiceBrowserNew`.
    func subscribeToRecordSignals() async throws -> [Task<Void, Never>] {
        let members = [
            AvahiNames.RecordBrowser.itemNew,
            AvahiNames.RecordBrowser.itemRemove,
            AvahiNames.RecordBrowser.failure,
        ]
        var tasks: [Task<Void, Never>] = []
        for member in members {
            let stream = try await signals(interface: AvahiNames.RecordBrowser.interface, member: member)
            tasks.append(
                Task { [weak self] in
                    for await message in stream {
                        guard !Task.isCancelled else { return }
                        await self?.receiveRecordSignal(message)
                    }
                })
        }
        return tasks
    }

    // MARK: - Following the service browser

    /// The service browser reported `peer` on one interface and protocol.
    func noteSighting(_ item: AvahiSignals.BrowseItem) {
        let key = "\(item.interfaceIndex)/\(item.networkProtocol)"
        let isNew = recordWatches[item.name] == nil
        recordWatchSightings[item.name, default: []].insert(key)
        guard isNew else { return }
        recordWatches[item.name] = PeerRecordWatch(peer: item.peer)
        browseTasks.append(Task { [weak self] in await self?.openRecordBrowser(for: item) })
    }

    /// The service browser withdrew `peer` from one interface and protocol.
    func noteDeparture(_ item: AvahiSignals.BrowseItem) {
        let key = "\(item.interfaceIndex)/\(item.networkProtocol)"
        recordWatchSightings[item.name]?.remove(key)
        guard recordWatchSightings[item.name]?.isEmpty ?? true else { return }
        recordWatchSightings[item.name] = nil
        recordWatches[item.name] = nil
        for (path, instance) in recordWatchPaths where instance == item.name {
            recordWatchPaths[path] = nil
            freeRecordBrowser(at: path)
        }
    }

    private func openRecordBrowser(for item: AvahiSignals.BrowseItem) async {
        let name = AvahiNames.serviceRecordName(
            instance: item.name, serviceType: item.serviceType, domain: item.domain)
        let path: String
        do {
            let reply = try await callServer(
                AvahiNames.recordBrowserNew,
                [
                    .int32(AvahiNames.unspecifiedInterface),
                    .int32(AvahiNames.unspecifiedProtocol),
                    .string(name),
                    .uint16(AvahiNames.dnsClassInternet),
                    .uint16(AvahiNames.dnsTypeTXT),
                    .uint32(0),
                ])
            guard case .objectPath(let answered) = reply.first else {
                throw AvahiError.unreadableReply(method: AvahiNames.recordBrowserNew)
            }
            path = answered
        } catch {
            // Not fatal to anything: the peer is still listed from its resolve,
            // it just will not be seen changing. Worth a notice, because that is
            // exactly the symptom this watch exists to prevent.
            logger.notice(
                "cannot follow a peer's record; changes to it will be missed",
                metadata: ["peer": "\(item.name)", "reason": "\(describe(error))"])
            return
        }
        // The peer left while the browser was being created.
        guard recordWatches[item.name] != nil else {
            freeRecordBrowser(at: path)
            return
        }
        recordWatchPaths[path] = item.name
        let waiting = unclaimedRecordSignals.filter { $0.path == path }
        unclaimedRecordSignals.removeAll { $0.path == path }
        for message in waiting { receiveRecordSignal(message) }
    }

    // MARK: - Signals

    func receiveRecordSignal(_ message: DBusMessage) {
        guard let path = message.path else { return }
        guard let instance = recordWatchPaths[path] else {
            claim(message, for: path)
            return
        }
        switch message.member {
        case AvahiNames.RecordBrowser.itemNew:
            recordArrived(message.body, for: instance)
        case AvahiNames.RecordBrowser.itemRemove:
            guard let item = AvahiSignals.recordItem(message.body), let watch = recordWatches[instance]
            else { return }
            recordWatches[instance] = watch.leaving(item.rdata)
        case AvahiNames.RecordBrowser.failure:
            logger.notice(
                "avahi stopped following a peer's record; changes to it will be missed",
                metadata: [
                    "peer": "\(instance)", "reason": "\(AvahiSignals.failureReason(message.body) ?? "")",
                ])
            recordWatchPaths[path] = nil
            freeRecordBrowser(at: path)
        default:
            return
        }
    }

    /// Holds a signal whose browser this side has not been told the path of
    /// yet — or which belongs to nobody here, in which case it ages out.
    func claim(_ message: DBusMessage, for path: String) {
        guard path.contains("/RecordBrowser") else { return }
        unclaimedRecordSignals.append(message)
        if unclaimedRecordSignals.count > Self.unclaimedSignalLimit {
            unclaimedRecordSignals.removeFirst(unclaimedRecordSignals.count - Self.unclaimedSignalLimit)
        }
    }

    private func recordArrived(_ body: [DBusValue], for instance: String) {
        guard let item = AvahiSignals.recordItem(body), item.recordType == AvahiNames.dnsTypeTXT,
            let watch = recordWatches[instance]
        else { return }
        let (next, outcome) = watch.arriving(item.rdata)
        recordWatches[instance] = next
        switch outcome {
        case .unchanged:
            return
        case .changed(let advertisement):
            emit(.changed(next.changedPeer(advertisement)))
        case .unreadable(let error):
            logger.notice(
                "a peer rewrote its record into something this build cannot read",
                metadata: ["peer": "\(instance)", "error": "\(error.description)"])
        }
    }

    // MARK: - Tearing down

    /// Frees every record browser. For a browse that is ending.
    func freeRecordWatches() {
        for path in recordWatchPaths.keys { freeRecordBrowser(at: path) }
        forgetRecordWatches()
    }

    /// Forgets every record browser without freeing it. For a browse whose
    /// daemon has already gone, taking the objects with it.
    func forgetRecordWatches() {
        recordWatches = [:]
        recordWatchSightings = [:]
        recordWatchPaths = [:]
        unclaimedRecordSignals = []
    }

    private func freeRecordBrowser(at path: String) {
        Task { [weak self] in
            await self?.free(
                path: path,
                interface: AvahiNames.RecordBrowser.interface,
                method: AvahiNames.RecordBrowser.free)
        }
    }
}

import DBUS
import Foundation
import SkrepkaSync

extension AvahiDiscovery {
    /// Starts browsing, or subscribes to the browse already running.
    ///
    /// One browse however many callers there are, and **each caller gets its
    /// own stream**. Handing back one shared stream would look like the same
    /// thing and is not: a stream has one buffer and delivers each element to
    /// exactly one consumer, so a peer list and a pairing coordinator reading
    /// the same stream would split the peers between them and each show a
    /// subset.
    ///
    /// Not `async`, because the protocol is not. The bus work therefore happens
    /// in a task, and a failure to start reaches the caller as
    /// ``SkrepkaSync/DiscoveryEvent/failed(_:)`` on the stream rather than as a
    /// throw — which is the same place `NWBrowser`'s asynchronous failures
    /// arrive, so a caller written against one backend handles the other.
    public func startBrowsing() throws -> AsyncStream<DiscoveryEvent> {
        let (stream, continuation) = AsyncStream<DiscoveryEvent>.makeStream()
        let id = UUID()
        eventSinks[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeEventSink(id) }
        }
        // A stream taken after the browse is already up would otherwise wait
        // for a `ready` that has been and gone, and a caller that gates
        // publishing on it — which the macOS coordinator does — would never
        // publish.
        if isBrowseReady {
            continuation.yield(.ready)
        } else if browserPath == nil, browseTasks.isEmpty {
            startBrowse()
        }
        return stream
    }

    /// Stops browsing and finishes every stream ``startBrowsing()`` handed out.
    /// Idempotent.
    public func stopBrowsing() {
        for task in browseTasks { task.cancel() }
        browseTasks = []
        isBrowseReady = false
        if let path = browserPath {
            browserPath = nil
            Task { [weak self] in
                await self?.free(
                    path: path,
                    interface: AvahiNames.Interface.serviceBrowser,
                    method: AvahiNames.Browser.free
                )
            }
        }
        for sink in eventSinks.values { sink.finish() }
        eventSinks = [:]
    }

    func removeEventSink(_ id: UUID) {
        eventSinks[id] = nil
    }

    func emit(_ event: DiscoveryEvent) {
        for sink in eventSinks.values { sink.yield(event) }
        // `failed` is terminal: the stream finishes immediately after it, and a
        // caller that wants to keep looking starts a new browse. Same contract
        // `NWBrowser` states for `nw_browser_state_failed`, and what avahi's
        // `ServiceBrowser` needs after a `Failure` signal — the browser object
        // is dead and has to be replaced.
        if case .failed = event { stopBrowsing() }
    }

    // MARK: - Running the browse

    func startBrowse() {
        ensureServerWatch()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runBrowse()
            } catch {
                await self.emit(.failed(.browsingFailed(reason: await self.describe(error))))
            }
        }
        browseTasks.append(task)
    }

    /// Subscribes to all four browser signals, creates the browser, and fans
    /// its signals into the event streams.
    ///
    /// The subscriptions come first and that is the point: avahi's browser
    /// starts by itself and answers from its cache, so a subscription taken
    /// after `ServiceBrowserNew` returns can miss every peer that was already
    /// known. Subscribing on the interface before the object exists cannot miss
    /// anything, at the cost of having to filter by path — which is one
    /// comparison per message.
    private func runBrowse() async throws {
        let items = try await signals(
            interface: AvahiNames.Interface.serviceBrowser, member: AvahiNames.Browser.itemNew)
        let removals = try await signals(
            interface: AvahiNames.Interface.serviceBrowser, member: AvahiNames.Browser.itemRemove)
        let failures = try await signals(
            interface: AvahiNames.Interface.serviceBrowser, member: AvahiNames.Browser.failure)

        let path = try await newServiceBrowser()
        browserPath = path
        isBrowseReady = true
        recordBrowseWorking()
        emit(.ready)

        browseTasks.append(consume(items, at: path) { .appeared($0) })
        browseTasks.append(consume(removals, at: path) { .disappeared($0) })
        browseTasks.append(consumeFailures(failures, at: path))
    }

    private func newServiceBrowser() async throws -> String {
        let reply = try await callServer(
            AvahiNames.Server.serviceBrowserNew,
            [
                .int32(AvahiNames.unspecifiedInterface),
                .int32(AvahiNames.unspecifiedProtocol),
                .string(ServiceDescriptor.serviceType),
                // Empty domain means `local`, which avahi resolves itself.
                .string(""),
                .uint32(0),
            ]
        )
        guard case .objectPath(let path) = reply.first else {
            throw AvahiError.unreadableReply(method: AvahiNames.Server.serviceBrowserNew)
        }
        return path
    }

    private func consume(
        _ signals: AsyncStream<DBusMessage>,
        at path: String,
        as event: @escaping @Sendable (DiscoveredPeer) -> DiscoveryEvent
    ) -> Task<Void, Never> {
        Task { [weak self] in
            for await message in signals {
                guard !Task.isCancelled else { return }
                guard message.path == path, let item = AvahiSignals.browseItem(message.body) else {
                    continue
                }
                await self?.emit(event(item.peer))
            }
        }
    }

    private func consumeFailures(
        _ signals: AsyncStream<DBusMessage>,
        at path: String
    ) -> Task<Void, Never> {
        Task { [weak self] in
            for await message in signals {
                guard !Task.isCancelled else { return }
                guard message.path == path else { continue }
                let reason = AvahiSignals.failureReason(message.body) ?? "the browse failed"
                await self?.emit(.failed(.browsingFailed(reason: reason)))
                return
            }
        }
    }
}

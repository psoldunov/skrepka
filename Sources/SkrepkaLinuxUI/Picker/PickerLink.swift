import Foundation
import SkrepkaIPC

/// The picker's side of the session bus: one queue, consumed one call at a
/// time, with every answer posted back as a ``PickerEvent``.
///
/// The shape ``DaemonLink`` established for the Settings window, narrowed to
/// what a picker does — prefetch, search, copy, pin, delete, preview — and with
/// one addition: it watches `HistoryChanged` and re-prefetches, so the
/// controller's cache is warm and `show()` paints without a round trip. The
/// window writes commands synchronously from GTK's thread through the
/// `nonisolated` methods; everything the daemon says comes back through
/// `report`, on the concurrency pool, never a widget in sight.
public actor PickerLink {
    public typealias Connect = @Sendable () async throws -> any PickerDaemon
    public typealias Report = @Sendable (PickerEvent) -> Void

    enum Command: Sendable {
        case prefetch
        case search(String)
        case copy(hash: String, style: CopyStyle)
        case setPinned(hash: String, pinned: Bool)
        case delete(hash: String)
        case preview(hash: String)
        case shutdown
    }

    private let connect: Connect
    private let report: Report
    private let commands: AsyncStream<Command>
    private nonisolated let sink: AsyncStream<Command>.Continuation
    private var consumer: Task<Void, Never>?
    private var watching: Task<Void, Never>?
    /// The query the open list is showing, so a pin or a delete can redraw the
    /// same view rather than snapping it back to the full history.
    private var lastQuery = ""

    public init(connect: @escaping Connect, report: @escaping Report) {
        self.connect = connect
        self.report = report
        (commands, sink) = AsyncStream<Command>.makeStream()
    }

    /// Begins consuming, prefetches the history, and starts watching for
    /// changes. Idempotent.
    public func start(retryingAfter retry: Duration = .seconds(2)) {
        guard consumer == nil else { return }
        let commands = commands
        consumer = Task { [weak self] in await self?.consume(commands) }
        watching = Task { [weak self] in await self?.watchHistory(retryAfter: retry) }
        enqueue(.prefetch)
    }

    public nonisolated func refresh() { enqueue(.prefetch) }
    public nonisolated func search(_ query: String) { enqueue(.search(query)) }
    public nonisolated func preview(hash: String) { enqueue(.preview(hash: hash)) }
    public nonisolated func copy(hash: String, style: CopyStyle) {
        enqueue(.copy(hash: hash, style: style))
    }
    public nonisolated func setPinned(hash: String, pinned: Bool) {
        enqueue(.setPinned(hash: hash, pinned: pinned))
    }
    public nonisolated func delete(hash: String) { enqueue(.delete(hash: hash)) }

    /// Finishes what is queued and stops. Reports nothing more after.
    public func shutdown() async {
        enqueue(.shutdown)
        await consumer?.value
    }

    private nonisolated func enqueue(_ command: Command) { sink.yield(command) }

    // MARK: - The queue

    private func consume(_ commands: AsyncStream<Command>) async {
        for await command in commands where await handle(command) { return }
    }

    /// Runs one command. Answers whether it was the shutdown.
    private func handle(_ command: Command) async -> Bool {
        switch command {
        case .prefetch:
            await load(lastQuery.isEmpty ? nil : lastQuery)
        case .search(let query):
            lastQuery = query
            await load(query)
        case .copy(let hash, let style):
            await act {
                try await self.connect().copy(.hash(hash), style: style)
            } onSuccess: {
                self.report(.copied)
            }
        case .setPinned(let hash, let pinned):
            await act {
                try await self.connect().setPinned(.hash(hash), pinned)
            } onSuccess: {
                await self.refreshOpen()
            }
        case .delete(let hash):
            await act {
                try await self.connect().delete(.hash(hash))
            } onSuccess: {
                await self.refreshOpen()
            }
        case .preview(let hash):
            await loadPreview(hash: hash)
        case .shutdown:
            watching?.cancel()
            sink.finish()
            return true
        }
        return false
    }

    // MARK: - Reading

    /// Loads the history, or the matches for `query`, and reports it. A `nil`
    /// query is the full history, painted straight away; a real one is a search
    /// reply, tagged so a stale one can be dropped.
    private func load(_ query: String?) async {
        do {
            let daemon = try await connect()
            if let query {
                report(.results(query: query, rows: try await daemon.search(query, limit: 0).clips))
            } else {
                report(.history(try await daemon.history(limit: 0).clips))
            }
        } catch {
            report(.unreachable(for: error))
        }
    }

    private func refreshOpen() async {
        await load(lastQuery.isEmpty ? nil : lastQuery)
    }

    private func loadPreview(hash: String) async {
        // A preview that fails is not worth a footer error: the row keeps its
        // kind tile, which is a fine second choice, and the next scroll asks
        // again.
        guard let document = try? await connect().preview(.hash(hash), maxBytes: 0) else { return }
        report(.preview(hash: hash, document: document))
    }

    /// Runs a mutating call, reporting its refusal detail or running `onSuccess`.
    private func act(
        _ call: () async throws -> ActionDocument,
        onSuccess: () async -> Void
    ) async {
        do {
            let outcome = try await call()
            if outcome.ok {
                await onSuccess()
            } else {
                report(.failed(outcome.detail))
            }
        } catch {
            report(.failed(PickerEvent.unreachable(for: error).failureDetail))
        }
    }

    // MARK: - Watching

    /// Re-prefetches whenever the history changes, so the cache the controller
    /// paints from stays warm. The change is routed back through the queue
    /// rather than fetched here, so the daemon is only ever asked one thing at a
    /// time.
    private func watchHistory(retryAfter retry: Duration) async {
        while !Task.isCancelled {
            if let daemon = try? await connect(), let changes = try? await daemon.historyChanges() {
                for await _ in changes { enqueue(.prefetch) }
            }
            try? await Task.sleep(for: retry)
        }
    }
}

extension PickerEvent {
    /// The one-line detail of an unreachable event, for the footer.
    fileprivate var failureDetail: String {
        if case .unreachable(let headline, _) = self { return headline }
        return "Something went wrong"
    }
}

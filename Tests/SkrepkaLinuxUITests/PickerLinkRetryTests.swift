import Foundation
import SkrepkaIPC
import Testing

@testable import SkrepkaLinuxUI

/// Opening the picker re-reads a history whose last read failed.
///
/// The history is otherwise re-read only on `HistoryChanged`. At login the
/// app's first prefetch could fail — the daemon still coming up — and the
/// picker then painted an empty list, as if there were no history, until
/// something was copied.
@Suite("Picker: retrying a failed read when it opens", .timeLimit(.minutes(1)))
struct PickerLinkRetryTests {
    @Test("a history that failed to load is read again when the picker opens")
    func aFailedReadIsRetriedOnOpening() async throws {
        let daemon = FlakyHistoryDaemon(failing: 1)
        let (events, report) = Self.listEvents()
        var next = events.makeAsyncIterator()
        let link = PickerLink(connect: { daemon }, report: report)
        await link.start(retryingAfter: .seconds(60))

        let first = try #require(await next.next())
        guard case .unreachable = first else {
            Issue.record("expected the first read to fail, got \(first)")
            return
        }

        link.opened()

        let second = try #require(await next.next())
        guard case .history(let rows) = second else {
            Issue.record("expected the list on opening, got \(second)")
            return
        }
        #expect(rows.map(\.contentHash) == [FlakyHistoryDaemon.clip.contentHash])
        #expect(await daemon.historyCalls == 2)
        await link.shutdown()
    }

    @Test("a history that loaded is not read again just because the picker opened")
    func aGoodReadIsNotRepeated() async throws {
        let daemon = FlakyHistoryDaemon(failing: 0)
        let (events, report) = Self.listEvents()
        var next = events.makeAsyncIterator()
        let link = PickerLink(connect: { daemon }, report: report)
        await link.start(retryingAfter: .seconds(60))
        _ = try #require(await next.next())

        link.opened()
        // A refresh queued behind the opening is the sync point: once its
        // answer is in, the opening has been handled too.
        link.refresh()
        _ = try #require(await next.next())

        #expect(await daemon.historyCalls == 2)
        await link.shutdown()
    }

    @Test("a search that failed does not make opening the picker re-read the history")
    func aFailedSearchLeavesTheHistoryAlone() async throws {
        let daemon = FlakyHistoryDaemon(failing: 0, failingSearches: true)
        let (events, report) = Self.listEvents()
        var next = events.makeAsyncIterator()
        let link = PickerLink(connect: { daemon }, report: report)
        await link.start(retryingAfter: .seconds(60))
        _ = try #require(await next.next())
        link.search("hello")
        _ = try #require(await next.next())

        link.opened()
        // The sync point again: a refresh re-runs the open search, which
        // fails, and its answer comes after the opening's.
        link.refresh()
        _ = try #require(await next.next())

        #expect(await daemon.historyCalls == 1)
        await link.shutdown()
    }

    /// The list events a link reports, in order, and the `report` that feeds
    /// them. Settings, previews and transfer progress are dropped: they are
    /// not what these tests are about.
    static func listEvents() -> (AsyncStream<PickerEvent>, PickerLink.Report) {
        let (stream, sink) = AsyncStream<PickerEvent>.makeStream()
        return (
            stream,
            { event in
                switch event {
                case .history, .unreachable: sink.yield(event)
                case .results, .preview, .settings, .copied, .failed, .transfers: break
                }
            }
        )
    }
}

/// A daemon whose first `History` calls time out, as the calls that activated
/// the daemon at login did, and which answers one entry after that. Its
/// searches find nothing, or time out too.
actor FlakyHistoryDaemon: PickerDaemon {
    static let clip = ClipDocument(
        contentHash: "abc123",
        preview: "hello",
        kind: "text",
        isPinned: false,
        createdAt: Date(timeIntervalSince1970: 0),
        byteCount: 5,
        representations: ["public.utf8-plain-text"]
    )

    private var failuresLeft: Int
    private let failingSearches: Bool
    private(set) var historyCalls = 0

    init(failing failures: Int, failingSearches: Bool = false) {
        failuresLeft = failures
        self.failingSearches = failingSearches
    }

    func history(limit: UInt32) async throws -> HistoryDocument {
        historyCalls += 1
        guard failuresLeft == 0 else {
            failuresLeft -= 1
            throw IPCError.timedOut(member: SkrepkaInterface.Member.history, after: .seconds(10))
        }
        return HistoryDocument(clips: [Self.clip], total: 1)
    }

    func search(_ query: String, limit: UInt32) async throws -> HistoryDocument {
        guard !failingSearches else {
            throw IPCError.timedOut(member: SkrepkaInterface.Member.search, after: .seconds(10))
        }
        return HistoryDocument(clips: [], total: 0)
    }

    func copy(_ selector: ClipSelector, style: CopyStyle) async throws -> ActionDocument {
        .succeeded()
    }

    func setPinned(_ selector: ClipSelector, _ pinned: Bool) async throws -> ActionDocument {
        .succeeded()
    }

    func delete(_ selector: ClipSelector) async throws -> ActionDocument {
        .succeeded()
    }

    func preview(_ selector: ClipSelector, maxBytes: UInt32) async throws -> PreviewDocument {
        throw IPCError.noReply(member: SkrepkaInterface.Member.preview)
    }

    /// Ends at once without a change, so the watcher asks for no re-read and
    /// then waits out the long retry the tests start the link with.
    func historyChanges() async throws -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

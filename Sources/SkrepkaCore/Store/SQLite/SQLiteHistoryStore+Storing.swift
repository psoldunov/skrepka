// The Linux store's conformance to `SkrepkaSync.HistoryStoring`, in a file of its
// own so the six requirements are visible in one place beside the macOS
// conformance in `HistoryStore+Storing.swift`. Fenced to Linux with the rest of
// the SQLite engine (D-3).
#if os(Linux)

    import Foundation
    import SkrepkaSync

    /// `SQLiteHistoryStore` as a sync peer sees it.
    ///
    /// Empty because every requirement is already public API of the store: an
    /// actor-isolated synchronous method witnesses an `async` requirement, so the
    /// hop happens at the call site and nothing here needs a forwarding shim.
    ///
    /// The list is worth reading as a checklist rather than as boilerplate — it is
    /// what makes this type interchangeable with `HistoryStore` in
    /// `HistoryStoringTests`:
    ///
    /// - ``SQLiteHistoryStore/syncIndex(since:)`` — `+Sync.swift`, concealed
    ///   content filtered unconditionally.
    /// - ``SQLiteHistoryStore/applyRemote(_:)`` — `+Merge.swift`, one transaction.
    /// - ``SQLiteHistoryStore/tombstones(since:)`` and
    ///   ``SQLiteHistoryStore/recordTombstone(_:)`` — `+Sync.swift`.
    /// - ``SQLiteHistoryStore/payload(for:key:)`` — `+Sync.swift`, nil for bytes
    ///   this store does not hold *and* for concealed content, which it holds and
    ///   will not serve.
    /// - ``SQLiteHistoryStore/capture(_:payloads:)`` — `+Merge.swift`.
    extension SQLiteHistoryStore: HistoryStoring {}

#endif
